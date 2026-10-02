# frozen_string_literal: true

require "uri"
require "cgi"
require "open3"
require "rbconfig"

# Fictional local creators and API fixtures; no external API requests.
class MyMiniFactoryPluginTest
  class FakeCreatorLinkClient
    attr_reader :object_calls, :creator_calls
    attr_accessor :profile

    def initialize(payload)
      @payload = payload
      @profile = payload.is_a?(Hash) ? payload["designer"] : nil
      @object_calls = []
      @creator_calls = []
    end

    def object(id)
      @object_calls << id.to_s
      raise @payload if @payload.is_a?(Exception)
      Marshal.load(Marshal.dump(@payload))
    end

    def creator(username)
      @creator_calls << username
      raise @profile if @profile.is_a?(Exception)
      Marshal.load(Marshal.dump(@profile))
    end
  end

  def test_creator_card_preserves_native_actions_and_queues_selected_model_with_mount_prefix
    SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
    with_creator_model do |creator, model, source_link|
      assert_includes PluginManager.components_for(:creator_menu), Components::ManyfoldMyminifactory::CreatorMenu
      2.times { ManyfoldMyminifactory::CreatorMenu.install! }
      second = model.links.create!(url: "https://myminifactory.com/object/3d-print-other-example-92002")
      ["", "/manyfold"].each do |prefix|
        session = browser(@users.first)
        card = creator_card(creator_index_document(session, prefix), creator)
        items = card.css('a[href]')
        assert items.any? { |item| item["href"] == "#{prefix}/creators/#{creator.to_param}/edit" }
        assert items.any? { |item| item["href"] == "#{prefix}/creators/#{creator.to_param}" &&
          (item["data-method"] || item["data-turbo-method"]) == "delete" }
        assert_equal 1, creator_link_menu_items(card).size
        menu_link = creator_link_menu_items(card).first
        assert_equal "menuitem", menu_link["role"]
        assert_equal "presentation", menu_link.parent["role"]
        assert_equal "ul", menu_link.parent.parent.name
        refute_nil menu_link.at_css('i.bi.bi-link-45deg')
        uri = URI.parse(menu_link["href"])
        assert_equal "#{prefix}/manyfold_myminifactory/creator_link", uri.path
        assert_equal creator.to_param, CGI.parse(uri.query).fetch("creator_id").first
        client = FakeCreatorLinkClient.new(fake_creator_link_payload)
        with_link_client(client) { session.get(menu_link["href"].delete_prefix(prefix), env: {"SCRIPT_NAME" => prefix}) }
        assert_equal 200, session.response.status
        form = creator_link_form_document(session)
        assert_equal "#{prefix}/manyfold_myminifactory/creator_link", form["action"]
        assert_equal [source_link.id, second.id].sort,
          form.css('input[type="radio"][name="link_id"]').map { |radio| radio["value"].to_i }.sort
        assert_empty client.object_calls
        assert_empty client.creator_calls
        before = creator_model_snapshot(model)
        selected = prefix.empty? ? source_link : second
        post_creator_link(session, creator, selected.id, form, prefix)
        assert_equal 303, session.response.status
        assert_equal "#{session.request.base_url}#{prefix}/creators", session.response.location
        assert_equal "MyMiniFactory creator sync is queued.", session.request.flash[:notice]
        assert_equal [creator.id, @users.first.id, selected.id], creator_link_jobs.last[:args]
        assert_equal before, creator_model_snapshot(model)
        assert_empty creator.links.reload
      end
    end
  end

  def test_creator_menu_requires_key_valid_model_link_and_unlinked_profile
    with_creator_model do |creator, model, source_link|
      session = browser(@users.first)
      [nil, "", " ", "fictional-creator-api-key"].each do |key|
        SiteSettings.myminifactory_api_key = key
        assert_equal(key.present? ? 1 : 0, creator_link_menu_items(creator_card(creator_index_document(session), creator)).size)
      end
      ["https://myminifactory.com/users/example-profile-sync-studio",
        "http://www.myminifactory.com/profile/example-profile-sync-studio/store?ref=example"].each do |url|
        profile = creator.links.create!(url: url)
        assert_empty creator_link_menu_items(creator_card(creator_index_document(session), creator))
        profile.destroy!
      end
      source_link.destroy!
      ["https://example.invalid/object/example-92001",
        "https://myminifactory.com.example.invalid/object/example-92001",
        "https://user@myminifactory.com/object/example-92001",
        "https://myminifactory.com/users/example-profile-sync-studio"].each do |url|
        link = model.links.create!(url: url)
        assert_empty creator_link_menu_items(creator_card(creator_index_document(session), creator)), url
        link.destroy!
      end
      form = get_creator_link_form(session, creator)
      assert_empty form.css('input[name="link_id"]')
      assert form.at_css('input[type="submit"]')["disabled"]
      post_creator_link(session, creator, source_link.id, form)
      assert_equal 422, session.response.status
      assert_empty creator_link_jobs
    end
  end

  def test_creator_link_rejects_csrf_missing_key_invalid_and_foreign_model_links
    SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
    with_creator_model do |creator, model, source_link|
      with_native_model(name: "Unrelated fictional model") do |other_model|
        foreign = other_model.links.create!(url: "https://myminifactory.com/object/example-92002")
        invalid = model.links.create!(url: "https://example.invalid/object/example-92001")
        session = browser(@users.first)
        form = get_creator_link_form(session, creator)
        session.post(form["action"], params: {creator_id: creator.to_param, link_id: source_link.id},
          headers: {"HTTP_ORIGIN" => session.request.base_url})
        assert_equal 422, session.response.status
        original = creator.attributes
        before = creator_model_snapshot(model)
        [nil, "", "0", "invalid", foreign.id, invalid.id, [foreign.id]].each do |selection|
          form = get_creator_link_form(session, creator)
          post_creator_link(session, creator, selection, form)
          assert_equal 422, session.response.status, selection.inspect
        end
        SiteSettings.myminifactory_api_key = nil
        form = get_creator_link_form(session, creator)
        assert form.at_css('input[type="submit"]')["disabled"]
        post_creator_link(session, creator, source_link.id, form)
        assert_equal 422, session.response.status
        assert_empty creator_link_jobs
        assert_empty creator.links.reload
        assert_equal original, creator.reload.attributes
        assert_equal before, creator_model_snapshot(model)
      end
    end
  end

  def test_creator_link_requires_admin_local_creator_and_visible_models
    SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
    with_creator_model do |creator, model, source_link|
      session = browser(@users.last)
      document = creator_index_document(session)
      assert_empty creator_link_menu_items(creator_card(document, creator))
      token = document.at_css('meta[name="csrf-token"]')["content"]
      assert_creator_link_forbidden(session, creator.to_param, source_link.id, token)
      session = browser(@users.first)
      model.update!(sensitive: true)
      @users.first.update!(sensitive_content_handling: "hide")
      assert_empty creator_link_menu_items(creator_card(creator_index_document(session), creator))
      form = get_creator_link_form(session, creator)
      assert_empty form.css('input[name="link_id"]')
      refute_includes session.response.body, model.name
      post_creator_link(session, creator, source_link.id, form)
      assert_equal 422, session.response.status
      model.update!(sensitive: false)
      token = form.at_css('input[name="authenticity_token"]')["value"]
      assert_creator_link_forbidden(session, "missing-fictional-creator", source_link.id, token)
      creator.federails_actor.update_columns(local: false)
      assert_creator_link_forbidden(session, creator.to_param, source_link.id, token)
      assert_empty creator_link_jobs
      assert_empty creator.links.reload
    end
  end

  def test_creator_link_post_is_idempotent_if_a_profile_was_added_after_form_rendering
    SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
    with_creator_model do |creator, _model, source_link|
      session = browser(@users.first)
      form = get_creator_link_form(session, creator)
      profile = creator.links.create!(url: "http://myminifactory.com/profile/example-profile-sync-studio/store")
      2.times do
        post_creator_link(session, creator, source_link.id, form)
        assert_equal 303, session.response.status
        assert_equal "Creator is already linked to MyMiniFactory.", session.request.flash[:notice]
        assert_empty creator_link_jobs
        assert_equal [profile.id], creator.links.reload.pluck(:id)
      end
    end
  end

  def test_creator_sync_changes_only_creator_metadata_avatar_and_banner
    SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
    with_creator_model do |creator, model, source_link|
      original_url = "http://myminifactory.com/object/example-92001?ref=example"
      source_link.update!(url: original_url)
      filename = "creator-sync-kept.txt"
      contents = "Fictional local file survives creator sync.\n"
      File.binwrite(File.join(@library_path, model.path, filename), contents)
      local_file = model.model_files.create!(filename: filename)
      before = creator_model_snapshot(model)
      owners = creator.owners.pluck(:id)
      ids = [::Creator.order(:id).pluck(:id), ::Model.order(:id).pluck(:id)]
      client = FakeCreatorLinkClient.new(fake_creator_link_payload)
      downloads = []
      with_status_image_download(downloads) do
        with_link_client(client) do
          2.times { ManyfoldMyminifactory::CreatorSyncJob.perform_now(creator.id, @users.first.id, source_link.id) }
        end
      end
      creator.reload
      assert_equal ["92001"], client.object_calls
      assert_empty client.creator_calls
      assert_equal "Fictional Profile Sync Studio", creator.name
      assert_equal "example-profile-sync-studio", creator.slug
      assert_equal "Fictional synchronized creator biography.", creator.notes
      assert creator.avatar&.exists?
      assert creator.banner&.exists?
      assert_equal %w[https://example.invalid/fictional-avatar.png https://example.invalid/fictional-banner.png], downloads
      assert_equal ["https://www.myminifactory.com/users/example-profile-sync-studio"], creator.links.pluck(:url)
      refute_nil creator.links.first.synced_at
      assert_equal owners, creator.owners.pluck(:id)
      assert_equal ids, [::Creator.order(:id).pluck(:id), ::Model.order(:id).pluck(:id)]
      assert_equal before, creator_model_snapshot(model)
      assert_equal original_url, source_link.reload.url
      assert local_file.reload.attachment.exists?
      assert_equal contents, File.binread(File.join(@library_path, model.path, filename))
    end
  end

  def test_creator_sync_rejects_invalid_objects_and_creator_profiles_before_mutations
    SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
    with_creator_model do |creator, model, source_link|
      original = creator.attributes
      before = creator_model_snapshot(model)
      valid = fake_creator_link_payload
      [ManyfoldMyminifactory::ApiClient::Unavailable.new("Fictional API failure."),
        valid.merge("id" => 92002), valid.merge("designer" => nil),
        valid.merge("designer" => valid["designer"].merge("profile_url" => "https://example.invalid/users/studio")),
        valid.merge("designer" => valid["designer"].merge("username" => "other-studio"))].each do |response|
        client = FakeCreatorLinkClient.new(response)
        with_link_client(client) { ManyfoldMyminifactory::CreatorSyncJob.perform_now(creator.id, @users.first.id, source_link.id) }
        assert_equal ["92001"], client.object_calls
        assert_empty creator.links.reload
        assert_equal original, creator.reload.attributes
        assert_equal before, creator_model_snapshot(model)
      end
    end
  end

  def test_creator_sync_rechecks_permissions_key_visibility_and_link_association
    SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
    with_creator_model do |creator, model, source_link|
      original = creator.attributes
      client = FakeCreatorLinkClient.new(fake_creator_link_payload)
      with_link_client(client) do
        ManyfoldMyminifactory::CreatorSyncJob.perform_now(creator.id, @users.last.id, source_link.id)
        creator.federails_actor.update_columns(local: false)
        ManyfoldMyminifactory::CreatorSyncJob.perform_now(creator.id, @users.first.id, source_link.id)
        creator.federails_actor.update_columns(local: true)
        SiteSettings.myminifactory_api_key = nil
        ManyfoldMyminifactory::CreatorSyncJob.perform_now(creator.id, @users.first.id, source_link.id)
        SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
        model.update!(sensitive: true)
        @users.first.update!(sensitive_content_handling: "hide")
        ManyfoldMyminifactory::CreatorSyncJob.perform_now(creator.id, @users.first.id, source_link.id)
        model.update!(sensitive: false, creator: nil)
        ManyfoldMyminifactory::CreatorSyncJob.perform_now(creator.id, @users.first.id, source_link.id)
        source_link.destroy!
        ManyfoldMyminifactory::CreatorSyncJob.perform_now(creator.id, @users.first.id, source_link.id)
      end
      assert_empty client.object_calls
      assert_empty creator.links.reload
      assert_equal original, creator.reload.attributes
    end
  end

  def test_native_creator_resync_updates_profile_and_records_safe_errors_on_link
    SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
    with_creator_model do |creator, model, source_link|
      payload = fake_creator_link_payload
      payload["designer"].merge!("avatar_url" => nil, "cover_url" => nil)
      client = FakeCreatorLinkClient.new(payload)
      with_link_client(client) { ManyfoldMyminifactory::CreatorSyncJob.perform_now(creator.id, @users.first.id, source_link.id) }
      link = creator.links.reload.first
      refute_nil link
      assert_instance_of ManyfoldMyminifactory::CreatorDeserializer, link.deserializer
      before = creator_model_snapshot(model)
      first_sync = link.synced_at
      client.profile = payload["designer"].merge("bio" => "Updated fictional biography.")
      travel_to(first_sync + 60) do
        with_link_client(client) { ::UpdateMetadataFromLinkJob.perform_now(link: link, organize: false) }
      end
      assert_equal ["example-profile-sync-studio"], client.creator_calls
      assert_equal "Updated fictional biography.", creator.reload.notes
      assert_operator link.reload.synced_at, :>, first_sync
      assert_equal [link.id], creator.links.reload.pluck(:id)
      synced_at = link.synced_at
      client.profile = ManyfoldMyminifactory::ApiClient::Unavailable.new("Fictional API failure.")
      with_link_client(client) { ::UpdateMetadataFromLinkJob.perform_now(link: link, organize: false) }
      problem = link.problems.find_by!(category: "http_error")
      assert_equal "Fictional API failure.", problem.note
      refute_includes problem.note, "fictional-creator-api-key"
      assert_equal synced_at, link.reload.synced_at
      assert_equal before, creator_model_snapshot(model)
    end
  end

  def test_creator_menu_compatibility_renders_each_provider_once_in_both_install_orders
    shim = File.join(ManyfoldMyminifactory::Engine.root, "lib/manyfold_myminifactory/creator_menu.rb")
    program = <<~'RUBY'
      require "active_support/core_ext/object/blank"
      module ComponentsHelper
        def BurgerMenu(**arguments)
          yield
        end
      end
      module ActionView
        class Template
          attr_reader :virtual_path, :source
          def initialize(source)
            @virtual_path = "creators/_creator"
            @source = source
          end
          def render(view, locals, *arguments, **options)
            view.BurgerMenu do
              native_hook = source.include?(":creator_menu") ?
                PluginManager.components_for(:creator_menu).map { |item| view.render(item.new(creator: locals[:creator])) }.join : ""
              "Native edit;Native delete;" + native_hook
            end
          end
        end
      end
      class FictionalProvider
        def initialize(creator:); end
        def to_s; "MMF item;"; end
      end
      class OtherProvider < FictionalProvider
        def to_s; "Other item;"; end
      end
      module PluginManager
        def self.components_for(hook)
          [FictionalProvider, OtherProvider]
        end
      end
      class View
        include ComponentsHelper
        def capture(*arguments, &block); block.call(*arguments); end
        def render(component); component.to_s; end
        def content_tag(tag, content, **options); "<#{tag}>#{content}</#{tag}>"; end
        def safe_join(items); items.join; end
      end
      # Models the compatibility hook used by Cults3D without requiring that plugin.
      module OtherProviderPlugin
        module CreatorMenu
          CONTEXT = :@other_provider_creator_menu
          def self.install!
            ActionView::Template.prepend(TemplateContext)
            ComponentsHelper.prepend(MenuItems)
          end
          module TemplateContext
            def render(view, locals, *arguments, **options, &block)
              previous = view.instance_variable_get(CONTEXT)
              creator = locals[:creator] unless source.include?(":creator_menu")
              view.instance_variable_set(CONTEXT, creator)
              super
            ensure
              view.instance_variable_set(CONTEXT, previous)
            end
          end
          module MenuItems
            def BurgerMenu(**arguments, &block)
              creator = instance_variable_get(CONTEXT)
              return super unless creator && block
              super(**arguments) do |*block_arguments|
                original = capture(*block_arguments, &block)
                items = PluginManager.components_for(:creator_menu).map do |component|
                  content_tag(:li, render(component.new(creator: creator)), role: "presentation")
                end
                safe_join([original, *items])
              end
            end
          end
        end
      end
      require ARGV.fetch(0)
      if ARGV.fetch(1) == "other-first"
        OtherProviderPlugin::CreatorMenu.install!
        ManyfoldMyminifactory::CreatorMenu.install!
      elsif ARGV.fetch(1) == "ours-first"
        ManyfoldMyminifactory::CreatorMenu.install!
        OtherProviderPlugin::CreatorMenu.install!
      else
        ManyfoldMyminifactory::CreatorMenu.install!
      end
      2.times { ManyfoldMyminifactory::CreatorMenu.install! }
      ["No native hook", "PluginManager.components_for :creator_menu", "PluginManager.components_for( :creator_menu)"].each do |source|
        view = View.new
        creator = Object.new
        output = ActionView::Template.new(source).render(view, {creator: creator})
        ["Native edit;", "Native delete;", "MMF item;", "Other item;"].each do |item|
          abort "Duplicate or missing #{item}: #{output}" unless output.scan(item).size == 1
        end
        abort "Creator context leaked" unless view.instance_variable_get(ManyfoldMyminifactory::CreatorMenu::CONTEXT).nil?
      end
      puts "Each provider and native action rendered once."
    RUBY
    %w[ours-only other-first ours-first].each do |order|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", program, shim.to_s, order)
      assert status.success?, "Creator menu #{order} failed: #{stderr}#{stdout}"
      assert_equal "Each provider and native action rendered once.\n", stdout
    end
  end

  private

  def with_creator_model
    with_native_model(name: "Fictional original model") do |model|
      creator = ::Creator.create!(name: "Fictional creator #{SecureRandom.hex(6)}", notes: "Original fictional biography.",
        permission_preset: "member", owner: @users.first)
      model.update!(creator: creator)
      source_link = model.links.create!(url: "https://www.myminifactory.com/object/example-92001")
      yield creator, model, source_link
    ensure
      creator&.federails_actor&.update_columns(local: true) if creator&.persisted?
    end
  end

  def creator_index_document(session, prefix = "")
    session.get("/creators", env: {"SCRIPT_NAME" => prefix})
    assert_equal 200, session.response.status
    Nokogiri::HTML(session.response.body)
  end

  def creator_card(document, creator)
    card = document.css('.creator-card').find { |candidate| candidate.at_css('.card-title')&.text&.include?(creator.name) }
    refute_nil card, "Fictional creator is missing from the native creators page."
    card
  end

  def creator_link_menu_items(card)
    card.css('a[href]').select { |item| item.text.strip == "Link to MyMiniFactory" }
  end

  def get_creator_link_form(session, creator, prefix = "")
    session.get("/manyfold_myminifactory/creator_link", params: {creator_id: creator.to_param}, env: {"SCRIPT_NAME" => prefix})
    assert_equal 200, session.response.status
    creator_link_form_document(session)
  end

  def creator_link_form_document(session)
    form = Nokogiri::HTML(session.response.body).at_css('#myminifactory-creator-link-form')
    refute_nil form
    assert_equal "post", form["method"].downcase
    form
  end

  def post_creator_link(session, creator, link_id, form, prefix = "")
    token = form.at_css('input[name="authenticity_token"]')["value"]
    session.post("/manyfold_myminifactory/creator_link", params: {creator_id: creator.to_param, link_id: link_id, authenticity_token: token},
      env: {"SCRIPT_NAME" => prefix}, headers: {"HTTP_ORIGIN" => session.request.base_url})
  end

  def assert_creator_link_forbidden(session, creator_id, link_id, token)
    session.get("/manyfold_myminifactory/creator_link", params: {creator_id: creator_id})
    assert_equal 404, session.response.status
    session.post("/manyfold_myminifactory/creator_link", params: {creator_id: creator_id, link_id: link_id, authenticity_token: token},
      headers: {"HTTP_ORIGIN" => session.request.base_url})
    assert_equal 404, session.response.status
  end

  def creator_link_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ManyfoldMyminifactory::CreatorSyncJob }
  end

  def creator_model_snapshot(model)
    model.reload
    [model.attributes, model.links.order(:id).map(&:attributes), model.model_files.order(:id).map(&:attributes),
      model.owners.order(:id).pluck(:id)]
  end

  def fake_creator_link_payload
    fake_link_payload.merge("designer" => {"username" => "example-profile-sync-studio", "name" => "Fictional Profile Sync Studio",
      "bio" => "Fictional synchronized creator biography.",
      "profile_url" => "https://www.myminifactory.com/profile/example-profile-sync-studio/store?ref=example",
      "avatar_url" => "https://example.invalid/fictional-avatar.png", "cover_url" => "https://example.invalid/fictional-banner.png"})
  end
end
