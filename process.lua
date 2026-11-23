-- PoC: map OSM tags onto the COROS VSM layer schema observed in the original tiles.
-- Layer/attribute names mirror the originals; numeric code meanings are best-effort.

node_keys = { "amenity", "historic", "leisure", "place", "shop", "tourism", "natural", "man_made", "railway", "public_transport" }
way_keys  = { "highway", "waterway", "building", "landuse", "natural", "leisure", "aerialway", "railway", "barrier", "amenity" }

-- road class codes for layer L (attribute E), similar to the original
-- tiles by joining feature names against OSM tags (dominant matches):
-- 8=trunk, 9=primary, 10=secondary, 11=tertiary, 12=residential/unclassified,
-- 13=cycleway/footway, 14=service, 15=track, 29=steps/path, 2=rail, 3=subway, 24=construction
local highway_E = {
  motorway=7, trunk=8, primary=9, secondary=10, tertiary=11,
  unclassified=12, residential=12, living_street=12, service=14,
  pedestrian=29, steps=5, path=5, footway=5, cycleway=13, track=15,
  busway=17, construction=24, proposed=24,
  rail=2, subway=3, tram=4, light_rail=2
}

-- waterway codes for layer P (attribute E): stream=1, river=2, canal=3, drain=4, ditch=5
local waterway_E = { river=2, stream=1, canal=3, drain=4, ditch=5 }
local waterway_zoom = { river=11, canal=11, stream=13, drain=14, ditch=14 }

-- POI category codes for layer K (attribute E)
local poi_E = {
  convenience=1, bicycle=1, variety_store=1, sports=1,
  fast_food=5, restaurant=5, park=6, bus_stop=7, platform=7, station=8, stop=8,
  camp_site=11, supermarket=13, department_store=13, marketplace=13,
  cafe=19, pub=22, bar=22, nightclub=22, marina=23, car=24, car_repair=24, taxi=24,
  hospital=25, clinic=25, doctors=25, social_facility=25, cemetery=26,
  attraction=27, viewpoint=27, fuel=36, bicycle_rental=51, parking=52,
  toilets=53, drinking_water=54, swimming_pool=33, information=0
}

-- place codes for layer J (attribute E)
local place_E = {
  farm=0, city=2, town=6, village=7, hamlet=8, suburb=10, quarter=11,
  neighbourhood=12, isolated_dwelling=13, locality=16,
  motorway_junction=14, island=14, square=5
}

function node_function()
  local place = Find("place")
  if place ~= "" and place_E[place] then
    Layer("J")
    AttributeNumeric("E", place_E[place])
    local place_zoom = {city=4, town=6, village=9, hamlet=11, suburb=10, neighbourhood=12, square=12, locality=10}
    MinZoom(place_zoom[place] or 8)
    local name = Find("name")
    if name ~= "" then Attribute("X", name) end
  end

  local natural = Find("natural")
  if natural == "peak" then
    Layer("H")
    AttributeNumeric("E", 1)
    AttributeNumeric("c", 1)
    local name = Find("name")
    if name ~= "" then Attribute("X", name) end
    local ele = Find("ele")
    if ele ~= "" then AttributeNumeric("F", tonumber(ele) or 0) end
  end

  local amenity = Find("amenity")
  local shop = Find("shop")
  local tourism = Find("tourism")
  local leisure = Find("leisure")
  local historic = Find("historic")
  local pt = Find("public_transport")
  local cat = amenity ~= "" and amenity or shop ~= "" and shop or tourism ~= "" and tourism
              or leisure ~= "" and leisure or historic ~= "" and historic or pt
  local name = Find("name")
  if pt ~= "" and name ~= "" then
    -- transit stops go to layer I (E=2), matching the original schema
    Layer("I")
    AttributeNumeric("E", 2)
    Attribute("X", name)
  elseif cat and cat ~= "" and name ~= "" and poi_E[cat] and cat ~= "bus_stop" and cat ~= "platform" and cat ~= "station" and cat ~= "stop" then
    Layer("K")
    AttributeNumeric("E", poi_E[cat])
    Attribute("X", name)
  end
end

function way_function()
  local highway = Find("highway")
  if highway ~= "" and highway_E[highway] then
    Layer("L", Find("area") == "yes")
    AttributeNumeric("E", highway_E[highway])
    if highway == "track" or highway == "construction" or highway == "proposed" then MinZoom(14)
    elseif highway == "path" or highway == "footway" or highway == "steps" then MinZoom(13)
    elseif highway == "service" or highway == "cycleway" or highway == "pedestrian" then MinZoom(13)
    elseif highway == "residential" or highway == "unclassified" or highway == "living_street" then MinZoom(12)
    elseif highway == "tertiary" then MinZoom(11)
    elseif highway == "secondary" then MinZoom(10)
    elseif highway == "primary" then MinZoom(9)
    else MinZoom(8) end
    local name = Find("name")
    if name ~= "" then Attribute("X", name) end
    local ref = Find("ref")
    if ref ~= "" then AttributeNumeric("i", tonumber(ref) or 0) end  -- metadata declares i as Number
    if Find("bridge") ~= "" then AttributeNumeric("b", 1) end
    if Find("tunnel") ~= "" then AttributeNumeric("j", 2) else AttributeNumeric("j", 1) end
    -- note: no "C" attribute -- original L features almost never carry it
  end

  local waterway = Find("waterway")
  if waterway ~= "" and waterway_E[waterway] then
    Layer("P", Find("area") == "yes")
    AttributeNumeric("E", waterway_E[waterway])
    MinZoom(waterway_zoom[waterway] or 13)
    local name = Find("name")
    if name ~= "" then Attribute("X", name) end
    AttributeNumeric("N", Find("intermittent") == "yes" and 1 or 0)
    if waterway == "river" then
      Layer("O")  -- major waterways also in layer O (E=2) at z13 (layer minzoom)
      AttributeNumeric("E", 2)
      if name ~= "" then Attribute("X", name) end
    end
  end

  -- polygons: water -> N, buildings/landuse -> F, forest -> B
  if IsClosed() then
    local natural = Find("natural")
    local landuse = Find("landuse")
    local leisure = Find("leisure")
    local building = Find("building")
    if natural == "water" or Find("waterway") == "riverbank" then
      Layer("N", true)
      AttributeNumeric("E", 1)
      MinZoom(8)
    elseif building ~= "" then
      MinZoom(14)  -- COROS landscape ships no building outlines; roads outline them
    elseif natural == "wood" or landuse == "forest" then
      Layer("F", true)
      AttributeNumeric("E", 7)
      MinZoom(9)
    elseif landuse == "industrial" or landuse == "commercial" then
      Layer("B", true)
      AttributeNumeric("E", 4)
    elseif natural == "grass" or natural == "meadow" or natural == "scrub" or natural == "heath"
           or natural == "sand" or natural == "beach" or natural == "wetland" then
      Layer("F", true)  -- open natural ground (E=1 renders green)
      AttributeNumeric("E", 1)
      MinZoom(9)
    elseif leisure == "park" or leisure == "playground" or leisure == "garden" or leisure == "nature_reserve" then
      Layer("F", true)  -- parks (E=3)
      AttributeNumeric("E", 3)
      MinZoom(9)
    elseif natural ~= "" and natural ~= "water" then
      Layer("F", true)
      AttributeNumeric("E", 1)
      MinZoom(10)
    end
    -- other landuse (residential etc.) intentionally omitted: COROS landscape has no landuse fills
  end

  local railway = Find("railway")
  if railway == "rail" or railway == "narrow_gauge" or railway == "light_rail" then
    Layer("L")
    AttributeNumeric("E", 2)
    MinZoom(10)
    local name = Find("name")
    if name ~= "" then Attribute("X", name) end
    AttributeNumeric("j", 1)
  elseif railway == "subway" then
    Layer("L")
    AttributeNumeric("E", 3)
    MinZoom(11)
    local name = Find("name")
    if name ~= "" then Attribute("X", name) end
    AttributeNumeric("j", 1)
  elseif railway == "tram" then
    Layer("L")
    AttributeNumeric("E", 4)
    MinZoom(12)
    local name = Find("name")
    if name ~= "" then Attribute("X", name) end
    AttributeNumeric("j", 1)
  end

  local aerialway = Find("aerialway")
  if aerialway ~= "" then
    Layer("A")
    AttributeNumeric("E", 1)
    local name = Find("name")
    if name ~= "" then Attribute("X", name) end
  end
end
