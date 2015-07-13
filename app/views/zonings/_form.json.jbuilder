json.stores @planning ? (@planning.routes.select(&:vehicle).collect(&:vehicle).collect(&:store_start) + @planning.routes.select(&:vehicle).collect(&:vehicle).collect(&:store_stop)).uniq : @zoning.customer.stores do |store|
  json.extract! store, :id, :name, :street, :postalcode, :city, :country, :lat, :lng
end
json.zoning @zoning.zones do |zone|
  json.extract! zone, :id, :vehicle_id, :polygon
end
if @planning
  json.planning @planning.routes do |route|
    if route.vehicle
      json.vehicle_id route.vehicle.id
    end
    json.stops do
      json.array! route.stops.collect do |stop|
        destination = stop.destination
        json.extract! destination, :id, :ref, :name, :street, :detail, :postalcode, :city, :country, :lat, :lng, :comment
        json.active route.vehicle && stop.active
        if !@planning.customer.enable_orders
          json.extract! destination, :quantity
        end
        (json.take_over destination.take_over.strftime('%H:%M:%S')) if destination.take_over
        (json.open destination.open.strftime('%H:%M')) if destination.open
        (json.close destination.close.strftime('%H:%M')) if destination.close
        color = stop.destination.tags.find(&:color)
        (json.color color.color) if color
        icon = stop.destination.tags.find(&:icon)
        (json.icon icon.icon) if icon
      end
    end
  end
end
