require 'test_helper'

class V01::DestinationsTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include ActionDispatch::TestProcess

  require Rails.root.join("test/lib/devices/tomtom_base")
  include TomtomBase

  def app
    Rails.application
  end

  setup do
    @destination = destinations(:destination_one)
    @customer = customers(:customer_one)
  end

  def around
    Routers::RouterWrapper.stub_any_instance(:compute_batch, lambda { |url, mode, dimension, segments, options| segments.collect{ |i| [1000, 60, '_ibE_seK_seK_seK'] } } ) do
      yield
    end
  end

  def api(part = nil, param = {})
    part = part ? '/' + part.to_s : ''
    "/api/0.1/destinations#{part}.json?api_key=testkey1&" + param.collect{ |k, v| "#{k}=" + URI.escape(v.to_s) }.join('&')
  end

  test 'should return customer''s destinations' do
    get api()
    assert last_response.ok?, last_response.body
    assert_equal @destination.customer.destinations.size, JSON.parse(last_response.body).size
  end

  test 'should return customer''s destinations by ids' do
    get api(nil, 'ids' => @destination.id)
    assert last_response.ok?, last_response.body
    assert_equal 1, JSON.parse(last_response.body).size
    assert_equal @destination.id, JSON.parse(last_response.body)[0]['id']
  end

  test 'should return a destination' do
    get api(@destination.id)
    assert last_response.ok?, last_response.body
    assert_equal @destination.name, JSON.parse(last_response.body)['name']
  end

  test 'should create' do
    assert_difference('Destination.count', 1) do
      assert_difference('Stop.count', 0) do
        @destination.name = 'new dest'
        post api(), @destination.attributes.update({tag_ids: tags})
        assert last_response.created?, last_response.body
        assert_equal @destination.name, JSON.parse(last_response.body)['name']
      end
    end
  end

  test 'should create with geocode error' do
    Mapotempo::Application.config.geocode_geocoder.class.stub_any_instance(:code, lambda{ |*a| raise GeocodeError.new }) do
      assert_difference('Destination.count', 1) do
        assert_difference('Stop.count', 0) do
          @destination.name = 'new dest'
          post api(), @destination.attributes.update({tag_ids: tags})
          assert last_response.created?, last_response.body
          assert_equal @destination.name, JSON.parse(last_response.body)['name']
        end
      end
    end
  end

  test 'should create with none tag' do
    ['', nil, []].each do |tags|
      assert_difference('Destination.count', 1) do
        @destination.name = 'new dest'
        post api(), @destination.attributes.update({tag_ids: tags})
        assert last_response.created?, last_response.body
      end
    end
  end

  test 'should create bulk from csv' do
    assert_difference('Destination.count', 1) do
      assert_difference('Planning.count', 1) do
        put api(), replace: false, file: fixture_file_upload('files/import_destinations_one.csv', 'text/csv')
        assert last_response.ok?, last_response.body
        assert_equal 1, JSON.parse(last_response.body).size

        get api()
        assert_equal 1, JSON.parse(last_response.body)[0]['visits'][0]['tag_ids'].size
      end
    end
  end

  test 'should create bulk from json' do
    assert_difference('Destination.count', 1) do
      assert_difference('Planning.count', 1) do
        assert_difference('Stop.count',
          @customer.plannings.select{ |p| p.tags_compatible?([tags(:tag_one), tags(:tag_two)]) }.size * 2 +
          2 + @customer.vehicle_usage_sets[1].vehicle_usages.select{ |v| v.default_rest_duration }.size) do
          put api(), {
            planning: {
              name: 'Hey',
              ref: 'Hop',
              date: '2123-10-10',
              vehicle_usage_set_id: @customer.vehicle_usage_sets[1].id,
              zoning_ids: [zonings(:zoning_one).id]
            },
            destinations: [{
              name: 'Nouveau client',
              street: nil,
              postalcode: nil,
              city: 'Tule',
              state: 'Limousin',
              lat: 43.5710885456786,
              lng: 3.89636993408203,
              detail: nil,
              comment: nil,
              phone_number: nil,
              ref: 'z',
              tags: ['tag1', 'tag2'],
              geocoding_accuracy: nil,
              foo: 'bar',
              visits: [{
                ref: 'v1',
                quantities: [{deliverable_unit_id: deliverable_units(:deliverable_unit_one_one).id, quantity: 1}],
                open1: '08:00',
                close1: '12:00',
                open2: '14:00',
                close2: '18:00',
                take_over: nil,
                route: 'useless_because_of_zoning_ids',
                active: '1'
              },
              {
                ref: 'v2',
                quantity1_1: 2,
                open1: '14:00',
                close1: '18:00',
                open2: '20:00',
                close2: '21:00',
                priority: 0,
                take_over: nil,
                route: 'useless_because_of_zoning_ids',
                active: '1'
              }]
            }]
          }.to_json,
          'CONTENT_TYPE' => 'application/json'
          assert last_response.ok?, last_response.body
          assert_equal 1, JSON.parse(last_response.body).size, 'Bad response size: ' + last_response.body.inspect

          get api()
          assert_equal 2, JSON.parse(last_response.body).find{ |destination| destination['name'] == 'Nouveau client' }['tag_ids'].size

          # zoning sets stops out_of_route
          planning = Planning.last
          visits = planning.routes.find{ |r| !r.vehicle_usage }.stops.map(&:visit)
          assert_equal ['v1', 'v2'], visits.map(&:ref)
          assert_equal [1, 2], visits.flat_map{ |v| v.quantities.values }
          assert_nil visits.first.priority
          assert_nil visits.second.priority

          route = Route.last
          assert_equal [route.id], JSON.parse('[' + route.geojson_tracks.join(',') + ']').map{ |t| t['properties']['route_id'] }.uniq
          assert_equal [route.id], JSON.parse('[' + route.geojson_points.join(',') + ']').map{ |t| t['properties']['route_id'] }.uniq

          get '/api/0.1/plannings/ref:Hop.json?api_key=testkey1'
          planning = JSON.parse(last_response.body)
          assert_equal 'Hey', planning['name']
          assert_equal 'Hop', planning['ref']
          assert_equal @customer.vehicle_usage_sets[1].id, planning['vehicle_usage_set_id']
          assert planning['zoning_ids'].size > 0
        end
      end
    end
  end

  test 'should create bulk from json with time exceeding one day' do
    assert_difference('Destination.count', 1) do
      assert_difference('Planning.count', 1) do
        put api(), {
          planning: {
            name: 'Hey',
            ref: 'Hop',
            date: '2017-10-10',
            vehicle_usage_set_id: @customer.vehicle_usage_sets[1].id,
            zoning_ids: [zonings(:zoning_one).id]
          },
          destinations: [{
            name: 'Nouveau client',
            street: nil,
            postalcode: nil,
            city: 'Tule',
            state: 'Limousin',
            lat: 43.5710885456786,
            lng: 3.89636993408203,
            detail: nil,
            comment: nil,
            phone_number: nil,
            ref: 'z',
            tags: ['tag1', 'tag2'],
            geocoding_accuracy: nil,
            foo: 'bar',
            visits: [{
              ref: 'v1',
              quantities: [{deliverable_unit_id: deliverable_units(:deliverable_unit_one_one).id, quantity: 1}],
              open1: '20:00',
              close1: '32:00',
              open2: '38:00',
              close2: '44:00',
              take_over: nil,
              route: 'useless_because_of_zoning_ids',
              active: '1'
            },
            {
              ref: 'v2',
              quantity1_1: 2,
              open1: '12:00',
              close1: '18:00',
              open2: '32:00',
              close2: '36:00',
              priority: -4,
              take_over: nil,
              route: 'useless_because_of_zoning_ids',
              active: '1'
            }]
          }]
        }, as: :json
        assert last_response.ok?, last_response.body

        visits = JSON.parse(last_response.body)[0]['visits']

        assert_equal '20:00:00', visits[0]['open1']
        assert_equal '32:00:00', visits[0]['close1']
        assert_equal '38:00:00', visits[0]['open2']
        assert_equal '44:00:00', visits[0]['close2']

        assert_equal '12:00:00', visits[1]['open1']
        assert_equal '18:00:00', visits[1]['close1']
        assert_equal '32:00:00', visits[1]['open2']
        assert_equal '36:00:00', visits[1]['close2']
      end
    end
  end

  test 'should create bulk from json with ref vehicle' do
    assert_difference('Destination.count', 1) do
      assert_difference('Planning.count', 1) do
        assert_difference('Stop.count',
          @customer.plannings.select{ |p| p.tags_compatible?([tags(:tag_one), tags(:tag_two)]) }.size * 2 +
          2 + vehicle_usage_sets(:vehicle_usage_set_one).vehicle_usages.select{ |v| v.default_rest_duration }.size) do
          put api(), {
            planning: {
              name: 'Hey',
              ref: 'Hop',
              vehicle_usage_set_id: vehicle_usage_sets(:vehicle_usage_set_one).id
            },
            destinations: [{
              name: 'Nouveau client',
              street: nil,
              postalcode: nil,
              city: 'Tule',
              state: 'Limousin',
              lat: 43.5710885456786,
              lng: 3.89636993408203,
              detail: nil,
              comment: nil,
              phone_number: nil,
              ref: 'z',
              tags: ['tag1', 'tag2'],
              geocoding_accuracy: nil,
              foo: 'bar',
              visits: [{
                ref: 'v1',
                quantity1_1: 1,
                open1: '08:00',
                close1: '12:00',
                open2: '14:00',
                close2: '18:00',
                take_over: nil,
                route: '1',
                ref_vehicle: '003',
                active: true
              },
              {
                ref: 'v2',
                quantity1_1: 2,
                open1: '14:00',
                close1: '18:00',
                open2: '20:00',
                close2: '21:00',
                take_over: nil,
                route: '1',
                ref_vehicle: '003',
                active: true
              }]
            }]
          }.to_json,
          'CONTENT_TYPE' => 'application/json'
          assert last_response.ok?, last_response.body
          assert_equal 1, JSON.parse(last_response.body).size, 'Bad response size: ' + last_response.body.inspect

          get api()
          assert_equal 2, JSON.parse(last_response.body).find{ |destination| destination['name'] == 'Nouveau client' }['tag_ids'].size

          planning = Planning.last
          assert planning.routes.find{ |r| r.vehicle_usage.try(&:vehicle).try(&:ref) == '003' }.stops.select{ |s| s.is_a? StopVisit }.map(&:visit).map(&:ref) == ['v1', 'v2']
        end
      end
    end
  end

  test 'should save route after import' do
    put api(), {
      planning: {
        ref: 'r1',
        name: 'Hey',
        vehicle_usage_set_id: vehicle_usage_sets(:vehicle_usage_set_one).id
      },
      replace: true,
      destinations: [{
        name: 'Nouveau client',
        street: nil,
        postalcode: nil,
        city: 'Tule',
        state: 'Limousin',
        lat: 43.5710885456786,
        lng: 3.89636993408203,
        detail: nil,
        comment: nil,
        phone_number: nil,
        ref: 'z',
        tags: ['tag1', 'tag2'],
        geocoding_accuracy: nil,
        foo: 'bar',
        visits: [{
          ref: 'v1',
          quantity1_1: 1,
          open1: '08:00',
          close1: '12:00',
          open2: '14:00',
          close2: '18:00',
          take_over: nil,
          route: '1',
          ref_vehicle: '003',
          active: true
        },
        {
          ref: 'v2',
          quantity1_1: 2,
          open1: '14:00',
          close1: '18:00',
          open2: '20:00',
          close2: '21:00',
          take_over: nil,
          route: '1',
          ref_vehicle: '003',
          active: true
        }]
      }]
    }.to_json,
    'CONTENT_TYPE' => 'application/json'
    assert last_response.ok?, last_response.body

    planning = Planning.last
    assert_not_nil planning.routes.last.stop_drive_time
  end

  test 'should create bulk from json with tag_id' do
    assert_difference('Destination.count', 1) do
      assert_difference('Planning.count', 1) do
        assert_difference('Stop.count',
          @customer.plannings.select{ |p| p.tags_compatible?([tags(:tag_one), tags(:tag_two)]) }.size * 2 +
          2 + @customer.vehicle_usage_sets[0].vehicle_usages.select{ |v| v.active && v.default_rest_duration }.size) do
          put api(), {destinations: [{
            name: 'Nouveau client',
            street: nil,
            postalcode: nil,
            city: 'Tule',
            state: 'Limousin',
            lat: 43.5710885456786,
            lng: 3.89636993408203,
            detail: nil,
            comment: nil,
            phone_number: nil,
            ref: 'z',
            tag_ids: [tags(:tag_one).id, tags(:tag_two).id],
            geocoding_accuracy: nil,
            foo: 'bar',
            visits: [{
              ref: 'v1',
              quantity1_1: nil,
              open1: nil,
              close1: nil,
              open2: nil,
              close2: nil,
              take_over: nil,
              route: '1',
              active: '1'
            },{
              ref: 'v2',
              quantity1_1: nil,
              open1: nil,
              close1: nil,
              open2: nil,
              close2: nil,
              take_over: nil,
              route: '1',
              active: '1'
            }]
          }]}.to_json,
          'CONTENT_TYPE' => 'application/json'
          assert last_response.ok?, last_response.body
          assert_equal 1, JSON.parse(last_response.body).size, 'Bad response size: ' + last_response.body.inspect

          get api()
          assert_equal 2, JSON.parse(last_response.body).find{ |destination| destination['name'] == 'Nouveau client' }['tag_ids'].size
        end
      end
    end
  end

  test 'should create bulk from json with visit ref' do
    assert_difference('Destination.count', 1) do
      assert_difference('Planning.count', 1) do
        assert_difference('Stop.count',
          @customer.plannings.select{ |p| p.tags_compatible?([tags(:tag_one), tags(:tag_two)]) }.size * 2 +
          2 + @customer.vehicle_usage_sets[0].vehicle_usages.select{ |v| v.active && v.default_rest_duration }.size) do
          put api(), {destinations: [{
            name: 'Nouveau client',
            street: nil,
            postalcode: nil,
            city: 'Tule',
            state: 'Limousin',
            lat: 43.5710885456786,
            lng: 3.89636993408203,
            detail: nil,
            comment: nil,
            phone_number: nil,
            ref: 'z',
            tags: ['tag1', 'tag2'],
            geocoding_accuracy: nil,
            foo: 'bar',
            visits: [{
              #to keep the same behavior between destinations refs and visits refs. visit can't be validated if no visit_ref have been settled.
              ref: 'v1',
              quantity1_1: 1,
              open1: '08:00',
              close1: '12:00',
              open2: '13:00',
              close2: '14:00',
              take_over: nil,
              route: '1',
              active: '1'
            },
            {
              quantity1_1: 2,
              ref: 'v2',
              open1: '14:00',
              close1: '18:00',
              open2: '20:00',
              close2: '21:00',
              take_over: nil,
              route: '1',
              active: '1'
            }]
          }]}.to_json,
          'CONTENT_TYPE' => 'application/json'
          assert last_response.ok?, last_response.body
          assert_equal 1, JSON.parse(last_response.body).size, 'Bad response size: ' + last_response.body.inspect

          get api()
          assert_equal 2, JSON.parse(last_response.body).find{ |destination| destination['name'] == 'Nouveau client' }['tag_ids'].size
        end
      end
    end
  end

  test 'should create bulk from json without visit' do
    assert_difference('Destination.count', 1) do
      assert_no_difference('Visit.count') do
        assert_no_difference('Planning.count') do
          put api(), {destinations: [{
            name: 'Nouveau client',
            street: nil,
            postalcode: nil,
            city: 'Tule',
            state: 'Limousin',
            lat: 43.5710885456786,
            lng: 3.89636993408203,
            detail: nil,
            comment: nil,
            phone_number: nil,
            ref: 'z',
            tags: ['tag1', 'tag2'],
            geocoding_accuracy: nil,
            foo: 'bar',
            visits: []
          }]}.to_json,
          'CONTENT_TYPE' => 'application/json'
          assert last_response.ok?, last_response.body
          assert_equal 1, JSON.parse(last_response.body).size, 'Bad response size: ' + last_response.body.inspect

          get api()
          assert_equal 2, JSON.parse(last_response.body).find{ |destination| destination['name'] == 'Nouveau client' }['tag_ids'].size
        end
      end
    end
  end

  test 'should create bulk from json without empty route' do
    assert_difference('Destination.count', 1) do
      assert_difference('Visit.count', 1) do
        assert_difference('Planning.count', 1) do
          put api(), {
            planning: {
              name: 'Hey'
            },
            destinations: [{
              name: 'Nouveau client',
              street: nil,
              postalcode: nil,
              city: 'Tule',
              state: 'Limousin',
              lat: 43.5710885456786,
              lng: 3.89636993408203,
              detail: nil,
              comment: nil,
              phone_number: nil,
              ref: 'z',
              tags: ['tag1', 'tag2'],
              geocoding_accuracy: nil,
              foo: 'bar',
              visits: [{
                quantity1_1: 2,
                ref: 'v1',
                take_over: nil,
                route: '', # Should be imported in unplanned
                active: '1'
              }]
            }]
          }.to_json,
          'CONTENT_TYPE' => 'application/json'
          assert last_response.ok?, last_response.body
          assert_equal 1, JSON.parse(last_response.body).size, 'Bad response size: ' + last_response.body.inspect

          get api()
          assert_equal 2, JSON.parse(last_response.body).find{ |destination| destination['name'] == 'Nouveau client' }['tag_ids'].size
        end
      end
    end
  end

  test 'should not create bulk from json containing too many routes' do
    assert_no_difference('Destination.count') do
      assert_no_difference('Visit.count') do
        assert_no_difference('Stop.count') do
          put api(), {destinations: [{
            name: 'N1',
            city: 'Tule',
            lat: 43.5710885456786,
            lng: 3.89636993408203,
            visits: [{
              ref: 'v1',
              route: '1',
              active: '1'
            },
            {
              ref: 'v2',
              route: '2',
              active: '1'
            }]
          },
          {
            name: 'N2',
            city: 'Brive',
            lat: 45.158556,
            lng: 1.532553,
            visits: [{
              ref: 'v3',
              route: '3',
              active: '1'
            },
            {
              ref: 'v4',
              route: '4',
              active: '1'
            }]
          }]}.to_json,
          'CONTENT_TYPE' => 'application/json'
          assert !last_response.ok?, last_response.body
          assert_not_nil JSON.parse(last_response.body)['error'], 'Bad response: ' + last_response.body.inspect
        end
      end
    end
  end

  test 'should throw error when trying to import multi refs' do
    assert_no_difference('Destination.count', 1) do
      assert_no_difference('Planning.count', 1) do
        assert_no_difference('Stop.count',
          @customer.plannings.select{ |p| p.tags_compatible?([tags(:tag_one), tags(:tag_two)]) }.size * 2 +
          2 + @customer.vehicle_usage_sets[0].vehicle_usages.select{ |v| v.active && v.default_rest_duration }.size) do
          put api(), {destinations: [{
            name: 'Nouveau client',
            street: nil,
            postalcode: nil,
            city: 'Tule',
            state: 'Limousin',
            lat: 43.5710885456786,
            lng: 3.89636993408203,
            detail: nil,
            comment: nil,
            phone_number: nil,
            ref: 'z',
            tag_ids: [tags(:tag_one).id, tags(:tag_two).id],
            geocoding_accuracy: nil,
            foo: 'bar',
            visits: [{
              ref: 'v1',
              quantity1_1: nil,
              open1: nil,
              close1: nil,
              open2: nil,
              close2: nil,
              take_over: nil,
              route: '1',
              active: '1'
            },{
              ref: 'v1',
              quantity1_1: nil,
              open1: nil,
              close1: nil,
              open2: nil,
              close2: nil,
              take_over: nil,
              route: '1',
              active: '1'
            }]
          }]}.to_json,
          'CONTENT_TYPE' => 'application/json'
          assert_not last_response.ok?, last_response.body
          error_message = I18n.t('destinations.import_file.refs_duplicate', refs: "z | v1")
          assert_equal error_message, JSON.parse(last_response.body)["error"][0].scan(error_message)[0]
        end
      end
    end
  end

  test 'should create bulk from tomtom' do
    @customer = add_tomtom_credentials customers(:customer_one)

    with_stubs [:address_service_wsdl, :show_address_report] do
      assert_difference('Destination.count', 1) do
        put api(), replace: false, remote: :tomtom
        assert_equal 202, last_response.status, 'Bad response: ' + last_response.body
      end
    end
  end

  test 'should update a destination' do
    [
      tags(:tag_one).id.to_s + ',' + tags(:tag_two).id.to_s,
      [tags(:tag_one).id, tags(:tag_two).id],
      '',
      nil,
      []
    ].each do |tags|
      @destination.name = 'new name'
      put api(@destination.id), @destination.attributes.merge(tag_ids: tags, visits: [ref: 'api', quantity: 5]).to_json, 'CONTENT_TYPE' => 'application/json'
      assert last_response.ok?, last_response.body
      destination = JSON.parse(last_response.body)
      assert_equal @destination.name, destination['name']
      assert_equal 5, destination['visits'].find{ |v| v['ref'] == 'api' }['quantities'][0]['quantity']

      get api(@destination.id)
      assert last_response.ok?, last_response.body
      assert_equal @destination.name, JSON.parse(last_response.body)['name']
    end
  end

  test 'should destroy a destination' do
    assert_difference('Destination.count', -1) do
      delete api(@destination.id)
      assert_equal 204, last_response.status, last_response.body
    end
  end

  test 'should destroy multiple destinations' do
    assert_difference('Destination.count', -2) do
      delete api + "&ids=#{destinations(:destination_one).id},#{destinations(:destination_two).id}"
      assert_equal 204, last_response.status, last_response.body
    end

    assert_difference('Destination.count', -2) do
      delete api
      assert_equal 204, last_response.status, last_response.body
    end
  end

  test 'should geocode' do
    patch api('geocode'), format: :json, destination: { city: @destination.city, name: @destination.name, postalcode: @destination.postalcode, street: @destination.street, state: @destination.state }
    assert last_response.ok?, last_response.body
  end

  test 'should geocode with error' do
    Mapotempo::Application.config.geocode_geocoder.class.stub_any_instance(:code, lambda{ |*a| raise GeocodeError.new }) do
      patch api('geocode'), format: :json, destination: { city: @destination.city, name: @destination.name, postalcode: @destination.postalcode, street: @destination.street, state: @destination.state }
      assert last_response.ok?, last_response.body
    end
  end

  test 'should geocode complete' do
    patch api('geocode_complete'), format: :json, id: @destination.id, destination: { city: 'Montpellier', street: 'Rue de la Chaînerais' }
    assert last_response.ok?, last_response.body
  end

  test 'Update Destination' do
    visit = visits :visit_one
    destination_params = @destination.attributes.slice *@destination.attributes.keys - ['id']
    visit_attributes = visit.attributes.slice *visit.attributes.keys - ['created_at', 'updated_at']
    destination_params.merge! 'visits_attributes' => [visit_attributes]
    put api(@destination.id), destination_params
    assert last_response.ok?, last_response.body
  end

  test 'Update Destination with Deprecated Params' do
    visit = visits :visit_one
    destination_params = @destination.attributes.slice *@destination.attributes.keys - ['id']
    visit_attributes = visit.attributes.slice *visit.attributes.keys - ['created_at', 'updated_at']

    open_time = 15.hours.to_i
    visit_attributes.delete 'open1'
    visit_attributes['open'] = open_time

    close_time = 17.hours.to_i
    visit_attributes.delete 'close1'
    visit_attributes['close'] = close_time

    destination_params.merge! 'visits_attributes' => [ visit_attributes ]
    put api(@destination.id), destination_params
    assert last_response.ok?, last_response.body

    assert_equal open_time, visit.reload.open1
    assert_equal close_time, visit.reload.close1
  end

  test 'should use limitation' do
    customer = @destination.customer
    customer.destinations.delete_all
    customer.max_destinations = 1
    customer.save!

    assert_difference('Destination.count', 1) do
      post api(), @destination.attributes
      assert last_response.created?, last_response.body
    end

    assert_difference('Destination.count', 0) do
      post api(), @destination.attributes
      assert last_response.forbidden?, last_response.body
      assert_equal 'dépassement du nombre maximal de clients', JSON.parse(last_response.body)['message']
    end
  end
end
