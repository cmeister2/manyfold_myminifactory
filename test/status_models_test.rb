# frozen_string_literal: true

require "base64"
require "tempfile"

# Fictional imported rows and native models only; no purchase data or API requests.
class MyMiniFactoryPluginTest
  def test_status_and_import_share_tabs_with_mount_prefixes
    ["", "/manyfold"].each do |prefix|
      session = browser(@users.first)
      form = import_form(session, prefix)
      assert_myminifactory_tabs(session, prefix, active: "Import")
      post_json(session, "{broken", form, prefix)
      assert_equal 422, session.response.status
      assert_myminifactory_tabs(session, prefix, active: "Import")
      status_document(session, prefix)
      assert_myminifactory_tabs(session, prefix, active: "Status")
      assert_empty Nokogiri::HTML(session.response.body).css("#myminifactory-models tbody tr")

      session = browser(@users.last)
      status_document(session, prefix)
      assert_myminifactory_tabs(session, prefix, active: "Status", import_allowed: false)

      with_native_model do |model|
        session = browser(@users.first)
        get_link_form(session, model, prefix)
        assert_myminifactory_tabs(session, prefix, active: nil)
      end
    end
  end

  def test_status_table_maps_existing_links_by_id_and_escapes_imported_names
    SiteSettings.myminifactory_api_key = "fictional-link-api-key"
    entries = [model_entry(93001, name: "<script>fictional</script> Copper Dragon"),
      model_entry(93002, name: "Example Badger"), model_entry(93003, name: "Example Castle")]
    save_status_examples(entries)
    with_native_model(name: "Existing example native model") do |first|
      with_native_model(name: "Second example native model") do |second|
        first.links.create!(url: "https://www.myminifactory.com/object/3d-print-fictional-one-93001")
        first.links.create!(url: "https://myminifactory.com/object/3d-print-another-title-93001?ref=example")
        second.links.create!(url: "https://www.myminifactory.com/object/3d-print-fictional-two-93001")
        library_models.find_by!(myminifactory_id: 93001).update!(model: first)
        first.links.create!(url: "https://example.invalid/object/3d-print-fictional-93002")
        first.links.create!(url: "https://www.myminifactory.com.example.invalid/object/3d-print-fictional-93003")
        ["", "/manyfold"].each do |prefix|
          session = browser(@users.first)
          document = status_document(session, prefix)
          assert_equal ["Name", "ID", "Manyfold model"], document.css("#myminifactory-models thead th").map { |cell| cell.text.strip }
          assert_equal ["93001", "93002", "93003"], document.css("#myminifactory-models tbody tr").map { |row| row["data-myminifactory-id"] }
          assert_empty document.css("#myminifactory-models script")
          linked_row = status_model_row(document, 93001)
          assert_equal entries.first["name"], linked_row.css("td").first.text.strip
          links = linked_row.css('a[href]').select { |link| link["href"].start_with?("#{prefix}/models/") }
          assert_equal ["#{prefix}/models/#{first.to_param}", "#{prefix}/models/#{second.to_param}"].sort, links.map { |link| link["href"] }.sort
          assert_empty linked_row.css("form")
          [93002, 93003].each do |id|
            row = status_model_row(document, id)
            assert_includes row.text, "Not linked"
            refute_nil row.at_css("form")
          end
        end
      end
    end
  end

  def test_status_table_hides_private_native_models_and_create_buttons_from_members
    save_status_examples([model_entry(93101)])
    with_native_model(name: "Private example model") do |model|
      model.update!(permission_preset: "private")
      model.links.create!(url: "https://www.myminifactory.com/object/3d-print-private-example-93101")
      library_models.find_by!(myminifactory_id: 93101).update!(model: model)
      refute ::ModelPolicy.new(@users.last, model).show?
      session = browser(@users.last)
      document = status_document(session)
      row = status_model_row(document, 93101)
      assert_includes row.text, "Not linked"
      assert_empty row.css('a[href^="/models/"]')
      assert_empty row.css("form")
      refute_includes document.to_html, "/models/#{model.to_param}"

      session = browser(@users.first)
      row = status_model_row(status_document(session), 93101)
      assert_equal "/models/#{model.to_param}", row.at_css('a[href^="/models/"]')["href"]
      assert_empty row.css("form")

      model.update!(sensitive: true)
      @users.first.update!(sensitive_content_handling: "hide")
      document = status_document(session)
      row = status_model_row(document, 93101)
      assert_includes row.text, "Linked"
      refute_includes row.text, "Not linked"
      assert_empty row.css('a[href^="/models/"]')
      assert_empty row.css("form")
      refute_includes document.to_html, "/models/#{model.to_param}"
      refute_includes row.text, model.name
    end
  end

  def test_status_create_model_queues_normal_sync_with_images
    SiteSettings.myminifactory_api_key = "fictional-link-api-key"
    SiteSettings.default_library = @library.id
    save_status_examples([model_entry(93201, name: "Example Empty Model")])
    entry = library_models.find_by!(myminifactory_id: 93201)
    original_downloads = SiteSettings.pregenerate_downloads
    SiteSettings.pregenerate_downloads = true
    with_created_status_models do
      session = browser(@users.first)
      form = status_create_form(session, entry, "/manyfold")
      native_ids = ::Model.order(:id).pluck(:id)
      imported_at = SiteSettings.find_by!(var: IMPORT_KEY).updated_at
      jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.dup
      payload = fake_link_payload.merge("id" => 93201,
        "url" => "https://www.myminifactory.com/object/3d-print-fictional-copper-dragon-93201",
        "images" => [{"id" => 9320101, "is_primary" => true,
          "original" => {"url" => "https://example.invalid/fictional-preview.png"}}])
      client = FakeLinkClient.new(payload)
      with_link_client(client) { post_status_create(session, entry, form, "/manyfold") }
      assert_equal 303, session.response.status
      assert_equal "#{session.request.base_url}/manyfold/manyfold_myminifactory/", session.response.location
      created = entry.reload.model
      refute_nil created
      assert_equal native_ids.size + 1, ::Model.count
      assert_equal "Example Empty Model", created.name
      assert_equal @library.id, created.library_id
      assert_equal [@users.first.id], created.owners.pluck(:id)
      assert created.private?
      assert_equal [], created.model_files.to_a
      assert_equal [], created.links.to_a
      assert_empty client.calls
      new_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs - jobs_before
      sync_jobs = new_jobs.select { |job| job[:job] == ManyfoldMyminifactory::SyncJob }
      assert_equal 1, sync_jobs.length
      assert_equal [created.id, @users.first.id, "93201"], sync_jobs.first[:args]
      assert_empty new_jobs.select { |job| [::UpdateDatapackageJob, ::PrepareDownloadJob].include?(job[:job]) }
      assert_equal imported_at, SiteSettings.find_by!(var: IMPORT_KEY).updated_at
      assert_equal [], Dir.glob(File.join(@library_path, "**", "*"), File::FNM_DOTMATCH).reject { |path| File.directory?(path) }

      downloads = []
      with_status_image_download(downloads) do
        with_link_client(client) { ActiveJob::Base.deserialize(sync_jobs.first).perform_now }
      end
      created.reload
      assert_equal ["93201"], client.calls
      assert_equal "Linked Copper Dragon", created.name
      assert_includes created.notes, "Fictional description."
      assert_equal ["example", "linked"], created.tag_list.sort
      assert_equal "Example Linking Studio", created.creator.name
      assert_nil created.creator.avatar
      assert_nil created.creator.banner
      assert_equal [payload["url"]], created.links.pluck(:url)
      refute_nil created.links.first.synced_at
      assert_equal created.id, entry.reload.model_id
      assert_equal ["https://example.invalid/fictional-preview.png"], downloads
      assert_equal 1, created.model_files.count
      image = created.model_files.find_by!(filename: "fictional-preview.png")
      refute_nil image.attachment
      assert image.attachment.exists?
      assert image.is_image?
      assert_equal image.id, created.preview_file_id

      row = status_model_row(status_document(session, "/manyfold"), 93201)
      assert_equal "/manyfold/models/#{created.to_param}", row.at_css('a[href^="/manyfold/models/"]')["href"]
      assert_empty row.css("form")
      sync_count = link_jobs.size
      with_link_client(client) { post_status_create(session, entry, form, "/manyfold") }
      assert_equal 303, session.response.status
      assert_equal native_ids.size + 1, ::Model.count
      assert_equal created.id, entry.reload.model_id
      assert_equal sync_count, link_jobs.size
      assert_equal ["93201"], client.calls

      form = import_form(session)
      post_json(session, JSON.generate([model_entry(93201, name: "Reimported Example Name")]), form)
      assert_equal 303, session.response.status
      assert_equal created.id, entry.reload.model_id
    end
  ensure
    SiteSettings.pregenerate_downloads = original_downloads
  end

  def test_status_create_model_reuses_existing_links_and_recovers_after_model_deletion
    SiteSettings.myminifactory_api_key = "fictional-link-api-key"
    SiteSettings.default_library = @library.id
    save_status_examples([model_entry(93301)])
    entry = library_models.find_by!(myminifactory_id: 93301)
    with_created_status_models do
      session = browser(@users.first)
      form = status_create_form(session, entry)
      post_status_create(session, entry, form)
      assert_equal 303, session.response.status
      created = entry.reload.model
      refute_nil created
      created.destroy!
      assert_nil entry.reload.model_id
      form = status_create_form(session, entry)
      post_status_create(session, entry, form)
      assert_equal 303, session.response.status
      replacement = entry.reload.model
      refute_nil replacement
      refute_equal created.id, replacement.id
      assert_equal [], replacement.model_files.to_a
      assert_equal [], replacement.links.to_a
    end

    with_native_model(name: "Already linked example") do |existing|
      existing.links.create!(url: "https://www.myminifactory.com/object/3d-print-already-linked-example-93301")
      session = browser(@users.first)
      document = status_document(session)
      token = document.at_css('meta[name="csrf-token"]')["content"]
      ids_before = ::Model.order(:id).pluck(:id)
      session.post("/manyfold_myminifactory/library_models/#{entry.id}/create_model",
        params: {authenticity_token: token}, headers: {"HTTP_ORIGIN" => session.request.base_url})
      assert_equal 303, session.response.status
      assert_equal ids_before, ::Model.order(:id).pluck(:id)
      row = status_model_row(status_document(session), 93301)
      assert_equal "/models/#{existing.to_param}", row.at_css('a[href^="/models/"]')["href"]
      assert_empty row.css("form")
    end
  end

  def test_status_create_model_requires_admin_csrf_and_an_imported_record
    SiteSettings.myminifactory_api_key = "fictional-link-api-key"
    SiteSettings.default_library = @library.id
    save_status_examples([model_entry(93401)])
    entry = library_models.find_by!(myminifactory_id: 93401)
    ids_before = ::Model.order(:id).pluck(:id)
    session = browser(@users.first)
    form = status_create_form(session, entry)
    session.post(form["action"], headers: {"HTTP_ORIGIN" => session.request.base_url})
    assert_equal 422, session.response.status
    assert_nil entry.reload.model_id
    assert_equal ids_before, ::Model.order(:id).pluck(:id)
    document = status_document(session)
    token = document.at_css('meta[name="csrf-token"]')["content"]
    session.post("/manyfold_myminifactory/library_models/0/create_model", params: {authenticity_token: token},
      headers: {"HTTP_ORIGIN" => session.request.base_url})
    assert_equal 404, session.response.status
    assert_equal ids_before, ::Model.order(:id).pluck(:id)

    session = browser(@users.last)
    document = status_document(session)
    token = document.at_css('meta[name="csrf-token"]')["content"]
    session.post("/manyfold_myminifactory/library_models/#{entry.id}/create_model", params: {authenticity_token: token},
      headers: {"HTTP_ORIGIN" => session.request.base_url})
    assert_equal 404, session.response.status
    assert_nil entry.reload.model_id
    assert_equal ids_before, ::Model.order(:id).pluck(:id)
  end

  def test_status_create_model_uses_the_library_fallback_when_default_is_missing
    SiteSettings.myminifactory_api_key = "fictional-link-api-key"
    SiteSettings.default_library = 0
    save_status_examples([model_entry(93501)])
    entry = library_models.find_by!(myminifactory_id: 93501)
    with_created_status_models do
      session = browser(@users.first)
      form = status_create_form(session, entry)
      expected_library = ::Library.default
      refute_nil expected_library
      post_status_create(session, entry, form)
      assert_equal 303, session.response.status
      assert_equal expected_library.id, entry.reload.model.library_id
      assert_equal [], entry.model.model_files.to_a
    end
  end

  def test_status_create_model_requires_an_api_key_before_creating_or_queueing
    SiteSettings.default_library = @library.id
    save_status_examples([model_entry(93601)])
    entry = library_models.find_by!(myminifactory_id: 93601)
    native_ids = ::Model.order(:id).pluck(:id)
    session = browser(@users.first)
    [nil, "", "   "].each do |key|
      SiteSettings.myminifactory_api_key = key
      document = status_document(session)
      assert_empty status_model_row(document, 93601).css("form")
      assert_includes document.text, "API key"
      token = document.at_css('meta[name="csrf-token"]')["content"]
      session.post("/manyfold_myminifactory/library_models/#{entry.id}/create_model",
        params: {authenticity_token: token}, headers: {"HTTP_ORIGIN" => session.request.base_url})
      assert_equal 303, session.response.status
      assert_equal "#{session.request.base_url}/manyfold_myminifactory/", session.response.location
      assert_equal native_ids, ::Model.order(:id).pluck(:id)
      assert_nil entry.reload.model_id
      assert_empty link_jobs
    end
  end

  private

  def save_status_examples(entries)
    json = JSON.generate(entries)
    ManyfoldMyminifactory::Inventory.parse(json).each { |attributes| library_models.create!(attributes) }
    SiteSettings.manyfold_myminifactory_import_json = json
  end

  def status_document(session, prefix = "")
    session.get("/manyfold_myminifactory/", env: {"SCRIPT_NAME" => prefix})
    assert_equal 200, session.response.status
    Nokogiri::HTML(session.response.body).tap do |document|
      refute_nil document.at_css("#myminifactory-models")
    end
  end

  def status_model_row(document, id)
    row = document.at_css("#myminifactory-models tbody tr[data-myminifactory-id='#{id}']")
    refute_nil row
    row
  end

  def status_create_form(session, entry, prefix = "")
    row = status_model_row(status_document(session, prefix), entry.myminifactory_id)
    form = row.at_css("form")
    refute_nil form
    assert_equal "post", form["method"].downcase
    assert_equal "#{prefix}/manyfold_myminifactory/library_models/#{entry.id}/create_model", form["action"]
    submit = form.at_css('input[type="submit"], button[type="submit"]')
    refute_nil submit
    assert_equal "Create Model", submit["value"] || submit.text.strip
    form
  end

  def post_status_create(session, entry, form, prefix = "")
    token = form.at_css('input[name="authenticity_token"]')["value"]
    session.post("/manyfold_myminifactory/library_models/#{entry.id}/create_model", params: {authenticity_token: token},
      env: {"SCRIPT_NAME" => prefix}, headers: {"HTTP_ORIGIN" => session.request.base_url})
  end

  def assert_myminifactory_tabs(session, prefix, active:, import_allowed: true)
    tabs = Nokogiri::HTML(session.response.body).at_css("#myminifactory-tabs")
    refute_nil tabs
    expected = import_allowed ? ["Status", "Import"] : ["Status"]
    assert_equal expected, tabs.css("a").map { |link| link.text.strip }
    tabs.css("a").each do |link|
      suffix = link.text.strip == "Import" ? "/import" : "/"
      assert_equal "#{prefix}/manyfold_myminifactory#{suffix}", link["href"]
      if link.text.strip == active
        assert_equal "page", link["aria-current"]
      else
        assert_nil link["aria-current"]
      end
    end
  end

  def with_status_image_download(downloads)
    singleton = Down.singleton_class
    original_download = Down.method(:download)
    temporary_files = []
    # One white PNG pixel exercises Shrine's normal upload and preview pipeline.
    png = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC")
    singleton.send(:define_method, :download) do |url, **options|
      downloads << url
      file = Tempfile.new(["fictional-myminifactory-image-", ".png"])
      file.binmode
      file.write(png)
      file.rewind
      file.define_singleton_method(:original_filename) { "fictional-preview.png" }
      temporary_files << file
      file
    end
    yield
  ensure
    singleton.send(:define_method, :download, original_download)
    temporary_files.each(&:close!)
  end

  def with_created_status_models
    native_ids = ::Model.pluck(:id)
    creator_ids = ::Creator.pluck(:id)
    tag_ids = ActsAsTaggableOn::Tag.pluck(:id)
    adapter = ActiveJob::Base.queue_adapter
    jobs_before = adapter.enqueued_jobs.dup
    yield
  ensure
    ::Model.where.not(id: native_ids).find_each do |model|
      federation_actor(model)&.update_columns(local: true)
      model.destroy!
    end
    ::Creator.where.not(id: creator_ids).find_each(&:destroy!)
    ActsAsTaggableOn::Tag.where.not(id: tag_ids).destroy_all
    adapter.enqueued_jobs.replace(jobs_before)
  end
end
