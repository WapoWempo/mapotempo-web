json.extract! store, :id, :name, :street, :postalcode, :city, :country, :lat, :lng, :geocoding_accuracy, :color, :icon
json.ref store.ref if @customer.enable_references
