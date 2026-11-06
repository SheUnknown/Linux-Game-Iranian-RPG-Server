-- Item registry (shared: the client reads labels/descriptions from here, the server decides everything).
-- Add an item here, give it a `use` id (handled in server.lua USE table) if it can be used.
INV_CFG = { slots = 30, maxWeight = 40.0 }          -- kg

ITEMS = {
  -- name          label              cat     weight stack  use       description
  water       = { label = "Water Bottle",  cat = "drink", weight = 0.5, stack = 10, use = "water",   desc = "Cold and refreshing. Restores a little health." },
  cola        = { label = "Cola",          cat = "drink", weight = 0.4, stack = 10, use = "cola",    desc = "Sugar rush. Restores a little health." },
  bread       = { label = "Bread",         cat = "food",  weight = 0.3, stack = 10, use = "bread",   desc = "Plain bread." },
  burger      = { label = "Burger",        cat = "food",  weight = 0.5, stack = 10, use = "burger",  desc = "Greasy but filling." },
  fish        = { label = "Fish",          cat = "food",  weight = 1.0, stack = 20,                  desc = "Fresh catch. Sell it or cook it." },
  bandage     = { label = "Bandage",       cat = "med",   weight = 0.2, stack = 10, use = "bandage", desc = "Stops the bleeding. +25 health." },
  medkit      = { label = "Medkit",        cat = "med",   weight = 1.5, stack = 3,  use = "medkit",  desc = "Professional kit. +60 health." },
  repair_kit  = { label = "Repair Kit",    cat = "tool",  weight = 2.0, stack = 3,  use = "repair",  desc = "Repairs the vehicle you are in." },
  lockpick    = { label = "Lockpick",      cat = "tool",  weight = 0.2, stack = 10,                  desc = "Opens simple locks. Not legal." },
  rope        = { label = "Rope",          cat = "tool",  weight = 1.0, stack = 5,                   desc = "Strong rope." },
  fishing_rod = { label = "Fishing Rod",   cat = "tool",  weight = 2.0, stack = 1,                   desc = "Needed for fishing." },
  phone       = { label = "Phone",         cat = "misc",  weight = 0.3, stack = 1,                   desc = "Your phone." },
  id_card     = { label = "ID Card",       cat = "doc",   weight = 0.1, stack = 1,                   desc = "Proof of identity." },
  car_key     = { label = "Car Key",       cat = "key",   weight = 0.1, stack = 1,                   desc = "Opens a vehicle." },
}
