# frozen_string_literal: true

abort "Run this test with bin/test in its disposable Manyfold container." unless
  ENV["MANYFOLD_MYMINIFACTORY_TEST"] == "1" && defined?(Rails.application)

require "minitest/autorun"
require "action_dispatch/testing/integration"
require "active_support/testing/time_helpers"
require "active_job/queue_adapters/test_adapter"
require "warden/test/helpers"
require "nokogiri"
require "tmpdir"
require "fileutils"

ActiveJob::Base.queue_adapter = :test
Warden.test_mode!

class MyMiniFactoryPluginTest < Minitest::Test
  include Warden::Test::Helpers
  include ActiveSupport::Testing::TimeHelpers

  IMPORT_KEY = "manyfold_myminifactory_import_json"

  def self.runnable_methods
    super.sort
  end

  def setup
    @original_key = SiteSettings.myminifactory_api_key
    @original_default_library = SiteSettings.default_library
    @original_import = SiteSettings.find_by(var: IMPORT_KEY)
    @original_json = @original_import&.value
    @original_models = library_models.order(:id).map(&:attributes)
    library_models.delete_all
    @original_csrf = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    @library_path = Dir.mktmpdir("myminifactory-status-test-")
    @library = Library.create!(name: "Status test", path: @library_path,
      storage_service: "filesystem", path_template: "{creator}/{modelName}")
    @users = [:administrator, :member].map do |role|
      identifier = SecureRandom.hex(8)
      User.create!(username: "status-#{identifier}", email: "#{identifier}@example.invalid",
        password: "Local-test-#{SecureRandom.hex(16)}", approved: true).tap { |user| user.add_role(role) }
    end
  end

  def teardown
    Warden.test_reset!
    @users&.each { |user| user.destroy! }
    @library&.destroy!
    SiteSettings.myminifactory_api_key = @original_key
    SiteSettings.default_library = @original_default_library
    if @original_import
      SiteSettings.manyfold_myminifactory_import_json = @original_json
      SiteSettings.find_by!(var: IMPORT_KEY).update_columns(updated_at: @original_import.updated_at)
    else
      SiteSettings.find_by(var: IMPORT_KEY)&.destroy!
    end
    library_models.delete_all
    @original_models&.each { |attributes| library_models.create!(attributes) }
    ActionController::Base.allow_forgery_protection = @original_csrf
    FileUtils.remove_entry(@library_path) if @library_path && File.exist?(@library_path)
  end

  def test_real_host_navigation_and_status_for_both_roles_and_all_settings
    assert_kind_of Rails::Engine, ManyfoldMyminifactory::Engine.instance
    expected_version = ENV["MANYFOLD_MYMINIFACTORY_EXPECTED_VERSION"]
    if expected_version.present?
      assert_equal expected_version, PluginManager.all.fetch("manyfold_myminifactory").version.to_s
    end
    assert_includes PluginManager.components_for(:navbar), Manyfold::ProviderMenu::Dropdown
    assert_includes PluginManager.components_for(:provider_menu), Components::ManyfoldMyminifactory::ProviderMenuItem

    @users.each do |user|
      [nil, "", "   ", "local-test-api-key"].each do |key|
        assert_navigation(user, key)
      end
    end
    [nil, "local-test-api-key"].each { |key| assert_navigation(@users.first, key, script_name: "/manyfold") }
  end

  def test_import_saves_exact_json_and_retains_invalid_input
    json = " \n" + JSON.pretty_generate([model_entry(2001, name: "<example> & \u00e9")]) + "\n "
    ["", "/manyfold"].each do |prefix|
      session = browser(@users.first)
      form = import_form(session, prefix)
      assert_equal 1, form.css("textarea").size
      assert_equal "", form.at_css("textarea").text.delete_prefix("\n")
      assert_equal ["submit"], form.css('input:not([type="hidden"])').map { |input| input["type"] }
      assert_equal "Save", form.at_css('input[type="submit"]')["value"]
      post_json(session, json, form, prefix)
      assert_equal 303, session.response.status
      assert_equal "1 model imported.", session.request.flash[:notice]
      assert_equal "#{session.request.base_url}#{prefix}/manyfold_myminifactory/import", session.response.location
      assert_equal json, saved_json
      imported_at = SiteSettings.find_by!(var: IMPORT_KEY).updated_at
      models_before = library_models.order(:id).map(&:attributes)
      assert_equal 1, models_before.length
      assert_equal "<example> & \u00e9", library_models.find_by!(myminifactory_id: 2001).name
      form = import_form(session, prefix)
      assert_equal "", form.at_css("textarea").text.delete_prefix("\n")

      ["{broken", "", ["unexpected", "array"]].each do |invalid|
        post_json(session, invalid, form, prefix)
        assert_equal 422, session.response.status
        assert_equal json, saved_json
        assert_equal imported_at, SiteSettings.find_by!(var: IMPORT_KEY).updated_at
        assert_equal models_before, library_models.order(:id).map(&:attributes)
        document = Nokogiri::HTML(session.response.body)
        assert_includes document.text, "Invalid JSON."
        expected = invalid.is_a?(String) ? invalid : ""
        assert_equal expected, document.at_css("textarea").text.delete_prefix("\n")
        form = document.at_css('form:has(textarea[name="json"])')
      end
    end
  end

  def test_import_requires_admin_and_csrf_token
    original = JSON.generate([model_entry(4001)])
    changed = JSON.generate([model_entry(4002)])
    session = browser(@users.first)
    form = import_form(session)
    post_json(session, original, form)
    assert_equal 303, session.response.status
    models_before = library_models.order(:id).map(&:attributes)
    imported_at = SiteSettings.find_by!(var: IMPORT_KEY).updated_at
    session.post("/manyfold_myminifactory/import", params: {json: changed},
      headers: {"HTTP_ORIGIN" => session.request.base_url})
    assert_equal 422, session.response.status
    assert_equal original, saved_json
    assert_equal models_before, library_models.order(:id).map(&:attributes)
    assert_equal imported_at, SiteSettings.find_by!(var: IMPORT_KEY).updated_at

    session = browser(@users.last)
    session.get("/manyfold_myminifactory/")
    assert_equal 200, session.response.status
    document = Nokogiri::HTML(session.response.body)
    assert_nil document.at_css('#myminifactory-tabs a[href$="/import"]')
    token = document.at_css('meta[name="csrf-token"]')["content"]
    origin = session.request.base_url
    session.get("/manyfold_myminifactory/import")
    assert_equal 404, session.response.status
    session.post("/manyfold_myminifactory/import", params: {json: changed, authenticity_token: token},
      headers: {"HTTP_ORIGIN" => origin})
    assert_equal 404, session.response.status
    assert_equal original, saved_json
    assert_equal models_before, library_models.order(:id).map(&:attributes)
    assert_equal imported_at, SiteSettings.find_by!(var: IMPORT_KEY).updated_at
  end

  def test_import_rejects_invalid_structure_without_partial_changes
    session = browser(@users.first)
    form = import_form(session)
    original = JSON.generate([model_entry(5001)])
    post_json(session, original, form)
    assert_equal 303, session.response.status
    imported_at = SiteSettings.find_by!(var: IMPORT_KEY).updated_at
    models_before = library_models.order(:id).map(&:attributes)

    invalid_payloads = [
      {"items" => [model_entry(5002)]},
      [model_entry(5002), model_entry(5003, name: "   ")],
      [model_entry(5002), model_entry(5003).merge("id" => "object-9999")],
      [model_entry(5002).merge("tags" => ["example", 123])],
      [model_entry(5002).merge("source" => nil)],
      [model_entry(5002).merge("creatorId" => "not-an-id")],
      [model_entry(5002).merge("creatorUsername" => 123)],
      [model_entry(5002).merge("creatorUsername" => "\n")],
      [model_entry(5002).merge("creatorAvatar" => [])],
      [model_entry(5002).merge("createdAt" => "not-a-date")],
      [model_entry(5002).merge("order" => {"id" => "not-an-id", "reference" => "EXAMPLE-ORDER"})],
      [model_entry(5002, source: "TRIBE").merge("release" => 123)],
      [model_entry(5002).merge("libraryAddedAt" => "not-a-date")],
      [model_entry(5002), nil]
    ]
    invalid_payloads.each do |payload|
      form = import_form(session)
      json = JSON.generate(payload)
      post_json(session, json, form)
      assert_equal 422, session.response.status
      assert_equal original, saved_json
      assert_equal imported_at, SiteSettings.find_by!(var: IMPORT_KEY).updated_at
      assert_equal models_before, library_models.order(:id).map(&:attributes)
      document = Nokogiri::HTML(session.response.body)
      assert_includes document.text, "Invalid JSON."
      assert_equal json, document.at_css("textarea").text.delete_prefix("\n")
    end
  end

  def test_import_updates_existing_rows_and_retains_absent_models
    session = browser(@users.first)
    form = import_form(session)
    post_json(session, JSON.generate([model_entry(6001), model_entry(6002)]), form)
    assert_equal 303, session.response.status
    assert_equal "2 models imported.", session.request.flash[:notice]
    original_model = library_models.find_by!(myminifactory_id: 6001)
    absent_model = library_models.find_by!(myminifactory_id: 6002).attributes
    updated = model_entry(6001, name: "Updated example model", source: "TRIBE").merge(
      "tags" => ["updated"], "libraryAddedAt" => "2025-02-01T12:00:00Z")

    form = import_form(session)
    json = JSON.generate([updated])
    post_json(session, json, form)
    assert_equal 303, session.response.status
    assert_equal "1 model imported.", session.request.flash[:notice]
    assert_equal json, saved_json
    assert_equal 2, library_models.count
    assert_equal absent_model, library_models.find_by!(myminifactory_id: 6002).attributes
    refreshed_model = library_models.find_by!(myminifactory_id: 6001)
    assert_equal original_model.id, refreshed_model.id
    assert_equal "Updated example model", refreshed_model.name
    assert_equal ["updated"], refreshed_model.tags
    assert_equal ["TRIBE"], refreshed_model.sources
    assert_equal Time.utc(2025, 2, 1, 12), refreshed_model.library_added_at
    assert_status_summary(session, 2, SiteSettings.find_by!(var: IMPORT_KEY).updated_at)
  end

  def test_import_preserves_milliseconds_and_accepts_null_optional_fields
    session = browser(@users.first)
    added_at = Time.utc(2025, 5, 1, 12) + Rational(123, 1000)
    milliseconds = Time.utc(2025, 5, 1, 12).to_i * 1000 + 123
    entry = model_entry(8001).merge("creatorName" => nil, "creatorId" => nil,
      "creatorUsername" => nil, "creatorAvatar" => nil, "createdAt" => milliseconds,
      "updatedAt" => nil, "publishedAt" => nil, "libraryAddedAt" => milliseconds, "tags" => [])

    [{}, {"id" => nil, "reference" => nil}, nil].each do |order|
      form = import_form(session)
      json = JSON.generate([entry.merge("order" => order)])
      post_json(session, json, form)
      assert_equal 303, session.response.status
      assert_equal json, saved_json
      assert_equal 1, library_models.count
      model = library_models.find_by!(myminifactory_id: 8001)
      assert_nil model.creator_name
      assert_nil model.creator_id
      assert_nil model.creator_username
      assert_nil model.creator_avatar
      assert_equal added_at, model.source_created_at
      assert_nil model.source_updated_at
      assert_nil model.published_at
      assert_equal added_at, model.library_added_at
      assert_equal [], model.tags
      assert_equal [{"source" => "PURCHASE", "library_added_at" => "2025-05-01T12:00:00.123000Z",
        "order_id" => nil, "order_reference" => nil, "release" => nil}], model.library_entries
    end
  end

  def test_status_counts_distinct_models_and_updates_import_time
    models = [
      [1001, "PURCHASE"], [1001, "TRIBE"], [1002, "PURCHASE"],
      [1003, "PURCHASE"], [1003, "TRIBE"],
      [1004, "PURCHASE"], [1004, "TRIBE"]
    ].map do |id, source|
      model_entry(id, source: source)
    end
    models[0].merge!("name" => "Earlier example model", "tags" => ["old", "shared"])
    models[1].merge!("name" => "Revised example model", "tags" => ["shared", "new"],
      "creatorName" => "Example Creator Two", "creatorId" => 9002,
      "creatorUsername" => "example-creator-two", "creatorAvatar" => "https://example.invalid/avatar.png",
      "createdAt" => "2024-03-01T09:00:00Z", "updatedAt" => "2024-04-01T09:00:00Z",
      "publishedAt" => "2024-03-02T09:00:00Z",
      "libraryAddedAt" => "2025-01-02T12:00:00Z")
    json = JSON.generate(models)
    session = browser(@users.first)
    form = import_form(session)
    first_import = Time.current.utc.change(usec: 0)
    database_ids = nil

    [first_import, first_import + 60].each do |imported_at|
      travel_to(imported_at) { post_json(session, json, form) }
      assert_equal 303, session.response.status
      assert_equal "4 models imported.", session.request.flash[:notice]
      assert_equal json, saved_json
      assert_equal imported_at, SiteSettings.find_by!(var: IMPORT_KEY).updated_at
      assert_equal 4, library_models.count
      current_ids = library_models.order(:myminifactory_id).pluck(:id)
      assert_equal database_ids, current_ids if database_ids
      database_ids = current_ids
      model = library_models.find_by!(myminifactory_id: 1001)
      assert_equal "Revised example model", model.name
      assert_equal "Example Creator Two", model.creator_name
      assert_equal 9002, model.creator_id
      assert_equal "example-creator-two", model.creator_username
      assert_equal "https://example.invalid/avatar.png", model.creator_avatar
      assert_equal Time.utc(2024, 3, 1, 9), model.source_created_at
      assert_equal Time.utc(2024, 4, 1, 9), model.source_updated_at
      assert_equal Time.utc(2024, 3, 2, 9), model.published_at
      assert_equal ["new", "old", "shared"], model.tags.sort
      assert_equal ["PURCHASE", "TRIBE"], model.sources.sort
      assert_equal Time.utc(2025, 1, 2, 12), model.library_added_at
      assert_equal [
        {"source" => "PURCHASE", "library_added_at" => "2025-01-01T12:00:00.000000Z",
         "order_id" => 8001, "order_reference" => "EXAMPLE-ORDER", "release" => nil},
        {"source" => "TRIBE", "library_added_at" => "2025-01-02T12:00:00.000000Z",
         "order_id" => nil, "order_reference" => nil, "release" => "EXAMPLE-RELEASE"}
      ], model.library_entries
      unchanged_model = library_models.find_by!(myminifactory_id: 1002)
      assert_nil unchanged_model.creator_username
      assert_nil unchanged_model.creator_avatar
      assert_equal Time.utc(2024, 1, 1, 9), unchanged_model.source_created_at
      assert_equal Time.utc(2024, 2, 1, 9), unchanged_model.source_updated_at
      assert_equal Time.utc(2024, 1, 2, 9), unchanged_model.published_at
      assert_status_summary(session, 4, imported_at)
      form = import_form(session)
    end
  end

  def test_status_counts_only_models_and_handles_empty_imports
    models = [
      model_entry(3001),
      model_entry(3001).merge("originalId" => "3001"),
      model_entry(3001).except("originalId"),
      {"originalId" => 3002, "type" => "print"},
      {"originalId" => 3003, "type" => "collection"}
    ]
    session = browser(@users.first)
    [[[], 0, "0 models imported."], [models, 1, "1 model imported."],
      [[], 1, "0 models imported."]].each do |entries, count, notice|
      form = import_form(session, "/manyfold")
      post_json(session, JSON.generate(entries), form, "/manyfold")
      assert_equal 303, session.response.status
      assert_equal notice, session.request.flash[:notice]
      assert_equal count, library_models.count
      imported_at = SiteSettings.find_by!(var: IMPORT_KEY).updated_at
      assert_status_summary(session, count, imported_at, "/manyfold")
    end
  end

  private

  def library_models
    ManyfoldMyminifactory::LibraryModel
  end

  # Fictional data only; none of these identifiers or metadata came from a purchase export.
  def model_entry(id, name: "Example model #{id}", source: "PURCHASE")
    {"originalId" => id, "id" => "object-#{id}", "type" => "object", "name" => name,
      "tags" => ["example", "test"], "source" => source,
      "createdAt" => "2024-01-01T09:00:00Z", "updatedAt" => "2024-02-01T09:00:00Z",
      "publishedAt" => "2024-01-02T09:00:00Z",
      "creatorUsername" => nil, "creatorName" => "Example Creator One", "creatorId" => 9001,
      "creatorAvatar" => nil, "libraryAddedAt" => "2025-01-01T12:00:00Z"}.tap do |entry|
      if source == "PURCHASE"
        entry["order"] = {"id" => 8001, "reference" => "EXAMPLE-ORDER"}
      else
        entry["release"] = "EXAMPLE-RELEASE"
      end
    end
  end

  def browser(user)
    Warden.test_reset!
    login_as(user, scope: :user)
    ActionDispatch::Integration::Session.new(Rails.application).tap do |session|
      session.host!(PublicUrl.hostname)
      session.https! if Rails.application.config.assume_ssl
    end
  end

  def import_form(session, prefix = "")
    environment = {"SCRIPT_NAME" => prefix}
    session.get("/manyfold_myminifactory/", env: environment)
    assert_equal 200, session.response.status
    document = Nokogiri::HTML(session.response.body)
    link = document.at_css('#myminifactory-tabs a[href$="/import"]')
    refute_nil link
    assert_equal "#{prefix}/manyfold_myminifactory/import", link["href"]
    session.get(link["href"].delete_prefix(prefix), env: environment)
    assert_equal 200, session.response.status
    form = Nokogiri::HTML(session.response.body).at_css('form:has(textarea[name="json"])')
    refute_nil form
    assert_equal "#{prefix}/manyfold_myminifactory/import", form["action"]
    form
  end

  def post_json(session, json, form, prefix = "")
    native_model_ids = ::Model.order(:id).pluck(:id)
    token = form.at_css('input[name="authenticity_token"]')["value"]
    session.post("/manyfold_myminifactory/import", params: {json: json, authenticity_token: token},
      env: {"SCRIPT_NAME" => prefix}, headers: {"HTTP_ORIGIN" => session.request.base_url})
    assert_equal native_model_ids, ::Model.order(:id).pluck(:id), "Import changed native Manyfold models."
  end

  def saved_json
    SiteSettings.find_by!(var: IMPORT_KEY).reload.value
  end

  def assert_status_summary(session, count, imported_at, prefix = "")
    session.get("/manyfold_myminifactory/", env: {"SCRIPT_NAME" => prefix})
    assert_equal 200, session.response.status
    document = Nokogiri::HTML(session.response.body)
    assert_equal ["#{count} models in database", "Imported at #{imported_at.strftime("%Y-%m-%d %H:%M:%S %Z")}"],
      document.css("#myminifactory-import-summary p").map { |paragraph| paragraph.text.strip }
    table = document.at_css("#myminifactory-models")
    refute_nil table
    assert_equal count, table.css("tbody tr").size
  end

  def assert_navigation(user, key, script_name: "")
    SiteSettings.myminifactory_api_key = key
    Warden.test_reset!
    login_as(user, scope: :user)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host!(PublicUrl.hostname)
    session.https! if Rails.application.config.assume_ssl
    environment = {"SCRIPT_NAME" => script_name}

    session.get("/models", env: environment)
    assert_equal 200, session.response.status
    assert_equal script_name, session.request.script_name
    document = Nokogiri::HTML(session.response.body)
    toggle = document.at_css("#main-navbar #nav-link-providers")
    refute_nil toggle, "Providers was missing from the host navbar."
    assert_equal "Providers", toggle.text.strip
    assert_equal "dropdown", toggle["data-bs-toggle"]
    assert_equal "providers-menu", toggle["aria-controls"]
    refute_nil toggle.at_css(".bi-plug"), "The Providers dropdown was missing its icon."
    assert_equal 1, document.css("#main-navbar #providers-menu").size
    assert_equal ["MyMiniFactory"], document.css("#providers-menu a.dropdown-item").map { |element| element.text.strip }
    refute document.css("#main-navbar a.nav-link").any? { |element| element.text.strip == "MyMiniFactory" }
    link = document.at_css("#providers-menu a.dropdown-item")
    refute_nil link, "MyMiniFactory was missing from the Providers dropdown."
    assert_equal "#{script_name}/manyfold_myminifactory", link["href"].delete_suffix("/")
    refute_nil link.at_css(".bi-box-seam"), "The provider menu item was missing its icon."

    # A reverse proxy strips its mount prefix from PATH_INFO and supplies SCRIPT_NAME.
    session.get(link["href"].delete_prefix(script_name), env: environment)
    assert_equal 200, session.response.status
    document = Nokogiri::HTML(session.response.body)
    plugin_link = document.css("#providers-menu a.dropdown-item").find { |element| element.text.strip == "MyMiniFactory" }
    refute_nil plugin_link
    assert_equal link["href"], plugin_link["href"], "The provider menu item changed its mount prefix."
    message = key.present? ? "myminifactory is linked" : "myminifactory not linked"
    paragraphs = document.css("main p").map { |paragraph| paragraph.text.strip }
    assert_includes paragraphs, message
    refute_includes paragraphs, key.present? ? "myminifactory not linked" : "myminifactory is linked"
    hrefs = document.css("#main-navbar a[href]").map { |element| element["href"] }
    assert_includes hrefs, "#{script_name}/dashboard"
    assert_includes hrefs, "#{script_name}/models"
  end
end

require_relative "library_matcher_test"
require_relative "link_services_test"
require_relative "link_test"
require_relative "status_models_test"
require_relative "provider_menu_test"
require_relative "creator_services_test"
require_relative "creator_link_test"
