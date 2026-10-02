# frozen_string_literal: true

require "minitest/autorun"
require "faraday"

# Fictional profiles and Faraday's test adapter; no external API requests.
class MyMiniFactoryCreatorServicesTest < Minitest::Test
  Source = ManyfoldMyminifactory::CreatorSource
  Deserializer = ManyfoldMyminifactory::CreatorDeserializer
  Client = ManyfoldMyminifactory::ApiClient
  PROFILE_URL = "https://www.myminifactory.com/users/Example%20Studio"

  def setup
    @original_key = SiteSettings.myminifactory_api_key
    SiteSettings.myminifactory_api_key = "fictional-creator-api-key"
  end

  def teardown
    SiteSettings.myminifactory_api_key = @original_key
  end

  def test_profile_and_store_urls_have_one_canonical_identity
    %w[users profile].each do |path|
      ["", "/", "/store", "/store/"].each do |suffix|
        ["http://myminifactory.com", "https://www.myminifactory.com"].each do |origin|
          source = Source.new("#{origin}/#{path}/Example%20Studio#{suffix}?page=2#profile")
          assert_equal "Example Studio", source.username
          assert_equal PROFILE_URL, source.uri
        end
      end
    end
  end

  def test_profile_urls_reject_foreign_hosts_credentials_ports_and_ambiguous_paths
    [nil, "", "Example Studio", "https://myminifactory.com.example.invalid/users/studio",
      "https://example.invalid/users/studio", "ftp://myminifactory.com/users/studio",
      "https://user:password@myminifactory.com/users/studio", "https://myminifactory.com:80/users/studio",
      "http://myminifactory.com:443/users/studio", "https://myminifactory.com:444/users/studio",
      "https://www.myminifactory.com/object/example-92001", "https://myminifactory.com/users/studio/collections",
      "https://myminifactory.com/users/a%2Fb", "https://myminifactory.com/users/studio%00",
      "https://myminifactory.com/users/%FF", "https://myminifactory.com/users/..",
      "https://myminifactory.com/users/%20studio"].each do |url|
      assert_raises(Source::Invalid, url.inspect) { Source.new(url) }
    end
  end

  def test_profile_payload_requires_a_matching_username
    assert_equal PROFILE_URL, Source.from_payload(creator_payload).uri
    assert_equal PROFILE_URL, Source.from_payload(creator_payload.except("profile_url")).uri
    assert_equal "https://www.myminifactory.com/users/Example%20St%C3%BAdio",
      Source.from_payload(creator_payload.merge("username" => "Example St\u00fadio", "profile_url" => nil)).uri
    assert Source.new(PROFILE_URL).matches?(creator_payload)
    [nil, {}, creator_payload.merge("username" => "Other Studio"),
      creator_payload.merge("profile_url" => "https://example.invalid/users/Example%20Studio"),
      creator_payload.merge("username" => ["Example Studio"])].each do |payload|
      assert_raises(Source::Invalid) { Source.from_payload(payload) }
      refute Source.new(PROFILE_URL).matches?(payload)
    end
    creator = Struct.new(:links).new([Struct.new(:url).new("https://myminifactory.com/object/example-92001")])
    refute Source.linked?(creator)
    creator.links << Struct.new(:url).new("http://myminifactory.com/profile/Example%20Studio/store?ref=example")
    assert Source.linked?(creator)
  end

  def test_api_creator_endpoint_escapes_username_and_uses_only_the_api_key
    client, requests = profile_client
    assert_equal creator_payload, client.creator("Example Studio")
    assert_equal 1, requests.size
    assert_equal({"key" => "fictional-creator-api-key"}, requests.first.params)
    assert_equal "/users/Example%20Studio", requests.first.url.path
    assert_equal "application/json", requests.first.request_headers["Accept"]
    refute requests.first.request_headers.key?("Authorization")
    [nil, "", "../studio", "studio/other", "studio\n", ["Example Studio"]].each do |username|
      assert_raises(Client::Error) { client.creator(username) }
    end
    assert_equal 1, requests.size
    client, requests = profile_client(api_key: " \t ")
    assert_raises(Client::ConfigurationError) { client.creator("Example Studio") }
    assert_empty requests
  end

  def test_creator_api_rejects_identity_mismatch_http_errors_and_unreadable_responses
    [nil, [], creator_payload.merge("username" => "Other Studio"),
      creator_payload.merge("profile_url" => "https://myminifactory.com/users/Other%20Studio")].each do |body|
      client, = profile_client(body: body)
      assert_raises(Client::InvalidResponse) { client.creator("Example Studio") }
    end
    {401 => Client::AuthenticationError, 404 => Client::NotFound, 429 => Client::RateLimited,
      500 => Client::Unavailable}.each do |status, error_class|
      client, = profile_client(status: status)
      error = assert_raises(error_class) { client.creator("Example Studio") }
      refute_includes error.message, "fictional-creator-api-key"
    end
    client, = profile_client(raw_body: "{broken")
    assert_raises(Client::InvalidResponse) { client.creator("Example Studio") }
    client, = profile_client(network_error: true)
    error = assert_raises(Client::Unavailable) { client.creator("Example Studio") }
    refute_includes error.message, "fictional-creator-api-key"
    assert_nil error.cause
  end

  def test_cached_profile_maps_native_creator_metadata_avatar_and_banner
    with_client(Object.new) do
      deserializer = Deserializer.new(uri: PROFILE_URL, payload: creator_payload)
      assert deserializer.valid?(for_class: ::Creator)
      refute deserializer.valid?(for_class: ::Model)
      assert_equal({name: "Fictional Example Studio", slug: "example-studio",
        notes: "A fictional studio.", links_attributes: [{url: PROFILE_URL}],
        avatar_remote_url: "https://cdn.example.invalid/avatar.png",
        banner_remote_url: "https://cdn.example.invalid/banner.png"}, deserializer.deserialize)
      assert_equal ::Creator, deserializer.capabilities[:class]
    end
  end

  def test_sparse_or_unsafe_images_do_not_replace_creator_images
    [nil, "http://cdn.example.invalid/avatar.png", "https://user:password@cdn.example.invalid/avatar.png",
      "https://cdn.example.invalid:444/avatar.png", "not a URL", ["https://example.invalid/avatar.png"]].each do |image|
      payload = creator_payload.merge("bio" => nil, "name" => nil, "avatar_url" => image, "cover_url" => image)
      attributes = Deserializer.new(uri: PROFILE_URL, payload: payload).deserialize
      assert_equal "Example Studio", attributes[:name]
      refute attributes.key?(:notes)
      refute attributes.key?(:avatar_remote_url)
      refute attributes.key?(:banner_remote_url)
    end
    assert_equal "", Deserializer.new(uri: PROFILE_URL, payload: creator_payload.merge("bio" => "")).deserialize[:notes]
    assert_raises(Client::InvalidResponse) do
      Deserializer.new(uri: PROFILE_URL, payload: creator_payload.merge("username" => "Other Studio")).deserialize
    end
  end

  def test_native_resync_fetches_decoded_username_and_converts_api_errors
    client = Object.new
    calls = []
    payload = creator_payload
    client.define_singleton_method(:creator) { |username| calls << username; payload }
    with_client(client) { assert_equal "A fictional studio.", Deserializer.new(uri: PROFILE_URL).deserialize[:notes] }
    assert_equal ["Example Studio"], calls
    [Client::Unavailable.new("Fictional API failure."), creator_payload.merge("username" => "Other Studio")].each do |response|
      client.define_singleton_method(:creator) { |_username| raise response if response.is_a?(Exception); response }
      with_client(client) do
        error = assert_raises(Faraday::Error) { Deserializer.new(uri: PROFILE_URL).deserialize }
        assert_nil error.cause
      end
    end
  end

  def test_factory_is_idempotent_and_preserves_other_deserializers
    2.times { ManyfoldMyminifactory::CreatorLinks.install! }
    assert_equal 1, ::Link.singleton_class.ancestors.count(ManyfoldMyminifactory::CreatorLinks::DeserializerFactory)
    assert_kind_of Deserializer, ::Link.deserializer_for(url: PROFILE_URL, for_class: ::Creator)
    fallback = Class.new { def self.deserializer_for(**arguments); arguments; end }
    fallback.singleton_class.prepend(ManyfoldMyminifactory::CreatorLinks::DeserializerFactory)
    other = "https://example.invalid/studio"
    assert_equal({url: other, for_class: ::Creator}, fallback.deserializer_for(url: other, for_class: ::Creator))
    assert_equal({url: PROFILE_URL, for_class: ::Model}, fallback.deserializer_for(url: PROFILE_URL, for_class: ::Model))
    SiteSettings.myminifactory_api_key = nil
    refute Deserializer.new(uri: PROFILE_URL, payload: creator_payload).valid?
    assert_equal({url: PROFILE_URL, for_class: ::Creator}, fallback.deserializer_for(url: PROFILE_URL, for_class: ::Creator))
    [nil, "", other, "https://myminifactory.com/object/example-92001"].each do |url|
      deserializer = Deserializer.new(uri: url, payload: creator_payload)
      refute deserializer.valid?
      assert_equal({}, deserializer.deserialize)
    end
  end

  private

  def creator_payload
    {"username" => "Example Studio", "name" => " Fictional Example Studio ", "bio" => " A fictional studio. ",
      "profile_url" => PROFILE_URL, "avatar_url" => "https://cdn.example.invalid/avatar.png",
      "cover_url" => "https://cdn.example.invalid/banner.png"}
  end

  def profile_client(api_key: "fictional-creator-api-key", status: 200, body: creator_payload, raw_body: nil, network_error: false)
    requests = []
    connection = Faraday.new do |builder|
      builder.response :json
      builder.adapter :test do |adapter|
        adapter.get("users/Example%20Studio") do |environment|
          requests << environment
          raise Faraday::TimeoutError, "fictional-creator-api-key should not be exposed" if network_error
          [status, {"Content-Type" => "application/json"}, raw_body || JSON.generate(body)]
        end
      end
    end
    [Client.new(api_key: api_key, connection: connection), requests]
  end

  def with_client(client)
    singleton = Client.singleton_class
    original = Client.method(:new)
    own_constructor = singleton.instance_methods(false).include?(:new)
    singleton.send(:define_method, :new) { |*arguments, **options, &block| client }
    yield
  ensure
    own_constructor ? singleton.send(:define_method, :new, original) : singleton.send(:remove_method, :new)
  end
end
