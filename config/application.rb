require File.expand_path('../boot', __FILE__)

require 'rails/all'
require_relative '../app/middleware/reseller_by_host'
require_relative '../lib/osrm'
require_relative '../lib/otp'
require_relative '../lib/here'
require_relative '../lib/ort'
require_relative '../lib/tomtom_webfleet'


# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Mapotempo
  class Application < Rails::Application
    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration should go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded.

    # Set Time.zone default to the specified zone and make Active Record auto-convert to this zone.
    # Run "rake -D time" for a list of tasks for finding time zone names. Default is UTC.
    # config.time_zone = 'Central Time (US & Canada)'

    # The default locale is :en and all translations from config/locales/*.rb,yml are auto loaded.
    # config.i18n.load_path += Dir[Rails.root.join('my', 'locales', '*.{rb,yml}').to_s]
    # config.i18n.default_locale = :de

    # Do not swallow errors in after_commit/after_rollback callbacks.
    config.active_record.raise_in_transactional_callbacks = true

    # Application config

    config.i18n.enforce_available_locales = true
    I18n.config.enforce_available_locales = true

    config.assets.initialize_on_precompile = true

    config.middleware.use Rack::Config do |env|
      env['api.tilt.root'] = Rails.root.join 'app', 'api', 'views'
    end

    config.middleware.insert_before 0, 'Rack::Cors' do
      allow do
        origins '*'
        resource '/api-web/0.1/*', headers: :any, methods: [:get, :post, :options, :put, :delete, :patch]
        resource '/api/0.1/*', headers: :any, methods: [:get, :post, :options, :put, :delete, :patch]
      end
    end

    config.middleware.use ::ResellerByHost

    config.lograge.enabled = true
    config.lograge.custom_options = lambda do |event|
      unwanted_keys = %w[format action controller]
      customer_id = event.payload[:customer_id]
      params = event.payload[:params].reject { |key,_| unwanted_keys.include? key }

      {customer_id: customer_id, time: event.time, params: params}
    end

    # Application config

    config.action_mailer.default_url_options = {host: 'localhost'}

    config.swagger_docs_base_path = 'http://localhost:3000/'

    config.optimize = Ort.new(
      ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'optimizer'), namespace: 'optimizer', expires_in: 60*60*24*10),
      'http://localhost:4567/0.1/optimize_tsptw'
    )
    config.optimize_time = 30000
    config.optimize_cluster_size = 5
    config.optimize_soft_upper_bound = 3

    config.geocode_code_cache = ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'geocode'), namespace: 'geocode', expires_in: 60*60*24*10)
    config.geocode_reverse_cache = ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'geocode_reverse'), namespace: 'geocode_reverse', expires_in: 60*60*24*10)
    config.geocode_complete_cache = ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'geocode_complete'), namespace: 'geocode_complete', expires_in: 60*60*24*10)
    config.geocode_ign_referer = 'localhost'
    config.geocode_ign_key = nil
    config.geocode_complete = false # Build time setting

    config.osrm = Osrm.new(
      ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'osrm_request'), namespace: 'osrm_request', expires_in: 60*60*24*1),
      ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'osrm_result'), namespace: 'osrm_result', expires_in: 60*60*24*1)
    )

    config.otp = Otp.new(
      ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'otp_request'), namespace: 'otp_request', expires_in: 60*60*24*1),
      ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'otp_result'), namespace: 'otp_result', expires_in: 60*60*24*1)
    )

    config.here = Here.new(
      ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'here_request'), namespace: 'here_request', expires_in: 60*60*24*1),
      ActiveSupport::Cache::FileStore.new(File.join(Dir.tmpdir, 'here_result'), namespace: 'here_result', expires_in: 60*60*24*1),
      'https://route.nlp.nokia.com/routing', nil, nil
    )

    config.tomtom = TomtomWebfleet.new('https://soap.business.tomtom.com/v1.25', nil)

    config.masternaut_api_url = 'http://ws.webservices.masternaut.fr/MasterWS/services'

    config.alyacom_api_url = 'http://partners.alyacom.fr/ws'
    config.alyacom_api_key = nil

    config.delayed_job_use = false

    config.self_care = true # Allow subscription and resiliation by the user himself

    config.geocoding_accuracy_success = 0.98
    config.geocoding_accuracy_warning = 0.9

    config.max_destinations = 3000
  end
end

ActionView::Base.field_error_proc = Proc.new do |html_tag, instance|
  class_attr_index = html_tag.index 'class="'

  if class_attr_index
    html_tag.insert class_attr_index+7, 'ui-state-error '
  else
    html_tag.insert html_tag.index('>'), ' class="ui-state-error"'
  end
end

module ActiveRecord
  module Validations
    class AssociatedBubblingValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        (value.is_a?(Enumerable) || value.is_a?(ActiveRecord::Associations::CollectionProxy) ? value : [value]).each do |v|
          unless v.valid?
            v.errors.full_messages.each do |msg|
              record.errors.add(attribute, msg, options.merge(:value => value))
            end
          end
        end
      end
    end

    module ClassMethods
      def validates_associated_bubbling(*attr_names)
        validates_with AssociatedBubblingValidator, _merge_attributes(attr_names)
      end
    end
  end
end

class TwitterBootstrapFormFor::FormBuilder
  def submit(value=nil, options={}, icon=false)
    value, options = nil, value if value.is_a?(Hash)
    options[:class] ||= 'btn btn-primary'
    value ||= submit_default_value
    @template.button_tag(options) {
      if icon != nil
        icon ||= 'fa-floppy-o'
        @template.concat @template.content_tag('i', nil, class: "fa #{icon} fa-fw")
      end
      @template.concat ' '
      @template.concat value
    }
  end
end
