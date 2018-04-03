local constants = require 'stonehearth.constants'
local csg_lib = require 'stonehearth.lib.csg.csg_lib'
local Point3 = _radiant.csg.Point3
local Cube3 = _radiant.csg.Cube3
local Region3 = _radiant.csg.Region3
local Transform = _radiant.csg.Transform
local MobEnums = _radiant.om.Mob
local RegionCollisionType = _radiant.om.RegionCollisionShape
local validator = radiant.validator
local log = radiant.log.create_logger('physics')

local PhysicsService = class()

local FLOAT_DEPTH = 0.15
local SINK_DEPTH = 0.10

function PhysicsService:initialize()
   self._sv = self.__saved_variables:get_data()
   self._blink = false

   if not self._sv.in_motion_entities then
      self._sv.new_entities = {}
      self._sv.floatable_entities = {}
      self._sv.in_motion_entities = {}
   end
   self._dirty_tiles = {}
   self._last_update_time = nil

   self._gameloop_trace = radiant.events.listen(radiant, 'radiant:gameloop:start', self, self._update)
   self._mob_physics_changed_trace = radiant.events.listen(radiant, 'radiant:mob:physics_changed', self, self.mob_physics_changed)

   -- Make this synchronous to make sure we process new entities before existing entities.
   -- e.g. we don't want a firepit to bump a tree!
   local entity_container = self:_get_root_entity_container()
   self._entity_container_trace = entity_container:trace_children('physics service', _radiant.dm.TraceCategories.SYNC_TRACE)
      :on_added(function(id, entity)
            self._sv.new_entities[id] = entity
         end)

   self._entity_post_create_trace = radiant.events.listen(radiant, 'radiant:entity:post_create', function(e)
         local entity = e.entity
         self._sv.new_entities[entity:get_id()] = entity
      end)


   self._dirty_tile_guard = _physics:add_notify_dirty_tile_fn(function(pt)
         self._dirty_tiles[pt:key_value()] = pt
      end, 0)

   self._mob_is_never_stuck_cache = {}

   assert(FLOAT_DEPTH > constants.hydrology.MERGE_ELEVATION_THRESHOLD)
end

function PhysicsService:_update()
   local dt = 1
   local now = radiant.gamestate.now()
   if self._last_update_time then
      dt = now - self._last_update_time
   end
   self._last_update_time = now
   self:_process_new_entities()
   self:_update_dirty_tiles()
   if dt > 0 then
      self:_update_floatable_entities()
      self:_update_in_motion_entities()
   end
end

function PhysicsService:_process_new_entities()
   for id, entity in pairs(self._sv.new_entities) do
      local ignore = false

      if self:_can_float(entity) then
         if self:_floating_supported(entity) then
            self._sv.floatable_entities[id] = entity
         else
            radiant.verify(false, '%s cannot float because floating is not currently supported for objects larger than 1x1', entity)
         end
      else
         -- for now, don't unstick child entities unless they can float
         -- otherwise building parts fall down
         local mob = entity:get_component('mob')
         local parent = mob and mob:get_parent()
         if parent ~= radiant.entities.get_root_entity() then
            ignore = true
         end
      end

      if not ignore then
         self:unstick_entity(entity)
      end
   end

   self._sv.new_entities = {}
end

function PhysicsService:_update_floatable_entities()
   if not self._sv.floatable_entities then
      return
   end

   for id, entity in pairs(self._sv.floatable_entities) do
      if entity:is_valid() then
         self:unstick_entity(entity)
      else
         self._sv.floatable_entities[id] = nil
      end
   end
end

function PhysicsService:_update_dirty_tiles()
   local dirty_tiles = self._dirty_tiles
   self._dirty_tiles = {}

   for _, pt in pairs(dirty_tiles) do
      log:detail('updating dirty tile %s', pt)
      for i=0,1 do
         for id, entity in pairs(_physics:get_physics_entities_in_tile(Point3(pt.x, pt.y + i, pt.z), 0)) do
            if id ~= radiant._root_entity_id then
               self:unstick_entity(entity)
            end
         end
      end
   end
end

function PhysicsService:set_blink(session, response, enabled)
   validator.expect_argument_types({'boolean'}, enabled)

   self._blink = enabled
end

function PhysicsService:blink_enabled()
   return self._blink
end

function PhysicsService:unstick_entity(entity)
   local stuck, unstick_method = self:_is_stuck(entity)
   if not stuck then
      return
   end

   log:debug('unsticking %s', entity)

   local mob = entity:get_component('mob')
   local mob_collision_type = mob:get_mob_collision_type()

   if mob_collision_type == MobEnums.CLUTTER then
      log:debug('destroying %s', entity)
      radiant.entities.destroy_entity(entity)
      return
   end

   if unstick_method == 'bump' then
      self:_bump_to_standable_location(entity)
   elseif unstick_method == 'fall' or unstick_method == 'float' then
      self:_set_free_motion(entity)
   else
      assert(false, 'unknown unstick method %s', unstick_method)
   end
end

function PhysicsService:mob_physics_changed(e)
   local entity = e.entity
   if entity and entity:is_valid() then
      local id = entity:get_id()
      self._mob_is_never_stuck_cache[id] = nil
   end
end

function PhysicsService:_is_stuck(entity)
   if not entity or not entity:is_valid() then
      return false
   end

   local id = entity:get_id()
   if self._mob_is_never_stuck_cache[id] then
      return false
   end

   local mob = entity:get_component('mob')
   if not mob then
      log:debug('%s has no mob component.  not unsticking', entity)
      self._mob_is_never_stuck_cache[id] = true
      return false
   end

   if mob:get_ignore_gravity() then
      log:debug('%s set to ignore gravity.  not unsticking', entity)
      self._mob_is_never_stuck_cache[id] = true
      return false
   end

   if mob:get_in_free_motion() then
      log:debug('%s already in free motion.  not unsticking', entity)
      return false
   end

   local mob_collision_type = mob:get_mob_collision_type()
   if mob_collision_type == MobEnums.NONE then
      local rcs = entity:get_component('region_collision_shape')
      local region_collision_type = rcs and rcs:get_region_collision_type()
      if region_collision_type ~= RegionCollisionType.SOLID then
         log:debug('%s is of type MobEnums.NONE and has a non-solid region.  not unsticking', entity)
         self._mob_is_never_stuck_cache[id] = true
         return false
      end
   end

   local current = mob:get_world_grid_location()
   if not current then
      log:debug('%s is not in the world.  not unsticking', entity)
      return false
   end

   if self:_should_float(entity) then
      return true, 'float'
   end

   local valid = _physics:get_standable_point(entity, current)
   local stuck = current ~= valid

   if stuck then
      local unstick_method = current.y < valid.y and 'bump' or 'fall'
      log:debug('%s unsticking via "%s"', entity, unstick_method)

      return true, unstick_method
   end

   -- Tiny items (but not creatures) have slightly different standability rules.
   -- TODO: Code these rules into the navgrid functions. Right now, it's possible
   -- to unstick a tiny item to a location where it could be considered stuck again,
   -- where it will stay stuck until its tile becomes dirty again. (We could also make
   -- a second pass on unsticking items, but this is just patching up the symptom.)
   if not mob:get_has_free_will() then
      if mob_collision_type == MobEnums.TINY or mob_collision_type == MobEnums.HUMANOID then
         if self:_is_supported_by_ladder_only(current) then
            log:debug('%s unsticking by "fall", since it is only supported by ladders', entity)
            return true, 'fall'
         end
      end

      if mob_collision_type == MobEnums.TINY then
         if self:_is_inside_platform(entity, current) then
            log:debug('%s unsticking by "bump", since it is tiny and inside a platform', entity)
            return true, 'bump'
         end
      end
   end

   return false
end

function PhysicsService:_can_float(entity)
   local physics_data = radiant.entities.get_entity_data(entity, 'stonehearth:physics')
   local can_float = physics_data and physics_data.floats
   return can_float
end

function PhysicsService:_floating_supported(entity)
   local rcs = entity:get_component('region_collision_shape')
   if not rcs then
      return true
   end

   local volume = rcs:get_region():get():get_area()
   local result = volume <= 1
   return result
end

function PhysicsService:_should_float(entity)
   if not self:_can_float(entity) then
      return false
   end

   local location = radiant.entities.get_world_grid_location(entity)
   if not location then
      return false
   end
   
   local point_below = location - Point3.unit_y

   local test_entities = radiant.terrain.get_entities_at_point(point_below)
   for _, test_entity in pairs(test_entities) do
      local water_component = test_entity:get_component('stonehearth:water')
      if water_component then
         local water_level = water_component:get_water_level()
         if water_level > location.y + SINK_DEPTH then
            return true
         end
      end
   end

   local region = Region3()
   region:add_point(location)
   region = csg_lib.get_non_diagonal_xz_inflated_region(region)

   test_entities = radiant.terrain.get_entities_in_region(region)
   for _, test_entity in pairs(test_entities) do
      local water_component = test_entity:get_component('stonehearth:water')
      if water_component then
         local water_level = water_component:get_water_level()
         if water_level > location.y + 1 + FLOAT_DEPTH then
            return true
         end
      end
   end

   return false
end

function PhysicsService:_is_supported_by_ladder_only(location)
   local point_below = location - Point3.unit_y
   -- quick rejection test
   if _physics:is_blocked(point_below, 0) then
      return false
   end

   local entities = radiant.terrain.get_entities_at_point(point_below)

   for other_id, other in pairs(entities) do
      if other_id == radiant._root_entity_id then
         return false
      end

      local rcs = other:get_component('region_collision_shape')
      local region_collision_type = rcs and rcs:get_region_collision_type()
      if region_collision_type == RegionCollisionType.SOLID or
         region_collision_type == RegionCollisionType.PLATFORM then
         return false
      end
   end

   return true
end

function PhysicsService:_is_inside_platform(entity, location)
   -- quick rejection test
   if not _physics:is_support(location, 0) then
      return false
   end

   local id = entity:get_id()
   local entities = radiant.terrain.get_entities_at_point(location)

   -- remove the entity from the test
   entities[id] = nil

   for other_id, other in pairs(entities) do
      local rcs = other:get_component('region_collision_shape')
      local region_collision_type = rcs and rcs:get_region_collision_type()
      if region_collision_type == RegionCollisionType.PLATFORM then
         return true
      end
   end

   return false
end

-- prioritize bumps to the same elevation, then up, then down
local function get_bump_penalty_normal(origin, candidate)
   local origin_y = origin.y
   local candidate_y = candidate.y

   if origin_y == candidate_y then
      return 0.0
   end

   if origin_y > candidate_y then
      return 0.5
   end

   -- origin_y < candidate_y
   return 1.0
end

local function get_bump_penalty_favor_up(origin, candidate)
   local new_origin = origin + Point3.unit_y
   return get_bump_penalty_normal(new_origin, candidate)
end

function PhysicsService:_bump_to_standable_location(entity)
   local mob = entity:add_component('mob')
   local candidates = {}
   local radius = 2
   local current = mob:get_world_location()
   local current_grid_location = current:to_closest_int()
   local search_origin = current_grid_location
   local bump_penalty_fn

   if _physics:get_standable_point(entity, current_grid_location) == current_grid_location then
      -- Even though the current location is standable, someone wanted us to find a better location.
      -- Let's bump up one block to see if we can find a better position.
      -- Used when tiny objects are stuck inside platforms (roofs).
      search_origin = search_origin + Point3.unit_y
      bump_penalty_fn = get_bump_penalty_favor_up
   else
      bump_penalty_fn = get_bump_penalty_normal
   end

   local get_candidate = function(location)
         local candidate = _physics:get_standable_point(entity, location)
         -- note that this uses the non-grid-aligned location, so it will favor
         -- some directions, which is what we want
         local distance = current:distance_to(candidate)
         local distance_penalty = bump_penalty_fn(current, candidate)
         local score = distance + distance_penalty
         local entry = {
            location = candidate,
            score = score
         }
         return entry
      end

   -- could be faster with an early exit or expanding radius search, but unstick doesn't run very often
   for j = -radius, radius do
      for i = -radius, radius do
         local direction = Point3(i, 0, j)
         local entry = get_candidate(search_origin + direction)
         table.insert(candidates, entry)
      end
   end

   table.sort(candidates, function(a, b)
         return a.score < b.score
      end)

   -- pick the candidate with the lowest score
   local selected = candidates[1].location

   log:debug('bumping %s to %s', entity, selected)
   mob:move_to(selected)
end

function PhysicsService:_set_free_motion(entity)
   log:debug('putting %s into free motion', entity)
   local mob = entity:add_component('mob')

   mob:set_in_free_motion(true)
   mob:set_velocity(Transform())

   local parent = mob:get_parent()
   if parent:get_id() ~= radiant._root_entity_id then
      -- object detaches from its parent and becomes a child of the root entity
      local location = radiant.entities.get_world_grid_location(entity)
      radiant.entities.remove_child(parent, entity)
      radiant.terrain.place_entity_at_exact_location(entity, location, { force_iconic = false })
   end

   self._sv.in_motion_entities[entity:get_id()] = entity
end

function PhysicsService:_update_in_motion_entities()
   for id, entity in pairs(self._sv.in_motion_entities) do
      if not self:_move_entity(entity) then
         self._sv.in_motion_entities[id] = nil
      end
   end
end

function PhysicsService:_move_entity(entity)
   local mob = entity:get_component('mob')
   if not mob then
      return false
   end

   local location = radiant.entities.get_world_grid_location(entity)
   if not location then
      return false
   end

   if not mob:get_in_free_motion() then
      log:debug('taking %s out of free motion', entity)
      return false
   end

   if self:_should_float(entity) then
      local new_location = location
      local above_point = location + Point3.unit_y

      local region = Region3()
      region:add_point(location)
      region = csg_lib.get_non_diagonal_xz_inflated_region(region)

      local test_entities = radiant.terrain.get_entities_in_region(region)
      for _, test_entity in pairs(test_entities) do
         local water_component = test_entity:get_component('stonehearth:water')
         if water_component then
            local water_level = water_component:get_water_level()
            if water_level > location.y + 1 + FLOAT_DEPTH then
               new_location = above_point
               radiant.entities.move_to(entity, new_location)

               local water_origin = radiant.entities.get_world_grid_location(test_entity)
               local region = Region3()
               region:add_point(location - water_origin)
               water_component:add_to_region(region)
               stonehearth.hydrology:_link_channels_for_block(location, test_entity)
               break
            end
         end
      end

      radiant.entities.move_to(entity, new_location)

      return true
   end

   -- Accleration due to gravity is 9.8 m/(s*s).  One block is one meter.
   -- You do the math (oh wait.  there isn't any! =)
   local acceleration = 9.8 / _radiant.sim.get_game_tick_interval();

   -- Update velocity.  Terminal velocity is currently 1-block per tick
   -- to make it really easy to figure out where the thing lands.
   local velocity = mob:get_velocity()

   log:debug('adding %.2f to %s current velocity %s', acceleration, entity, velocity)

   velocity.position.y = velocity.position.y - acceleration;
   velocity.position.y = math.max(velocity.position.y, -1.0);

   -- Update position
   local current = mob:get_transform()
   local nxt = Transform()
   nxt.position = current.position + velocity.position
   nxt.orientation = current.orientation

   -- when testing to see if we're blocked, make sure we look at the right point.
   -- `is_standable` will round to the closest int, so if we're at (1, -0.3, 1), it
   -- will actually test the point (1, 0, 1) when we wanted (1, -1, 1) !!
   local test_position = nxt.position - Point3(0, 0.5, 0)

   -- If our next position is blocked, fall to the bottom of the current
   -- brick and clear the free motion flag.
   local mob_collision_type = mob:get_mob_collision_type()
   local can_fall_through_ladders = (mob_collision_type == MobEnums.TINY or mob_collision_type == MobEnums.HUMANOID) and not mob:get_has_free_will()

   local next_position_standable = false
   if can_fall_through_ladders then
      next_position_standable = _physics:is_blocked(entity, test_position)
   else
      next_position_standable = _physics:is_standable(entity, test_position)
   end

   if next_position_standable then
      log:debug('%s next position %s is standable.  leaving free motion', entity, test_position)

      velocity.position = Point3.zero
      if can_fall_through_ladders then
         nxt.position.y = math.floor(current.position.y)
      else
         nxt.position.y = math.floor(test_position.y)
      end
      mob:set_in_free_motion(false)
   else
      log:debug('%s next position %s is not standable.  staying in free motion', entity, test_position)
   end

   local in_bounds = radiant.terrain.in_bounds(nxt.position)
   if not in_bounds then
      local pos_no_y = Point3(nxt.position.x, 0, nxt.position.z)
      local new_pos = radiant.terrain.get_point_on_terrain(pos_no_y)
      log:error('%s is at location: %s, which is not in bounds of the terrain. Placing it at %s', entity, nxt.position, new_pos)
      nxt.position.x = new_pos.x
      nxt.position.y = new_pos.y
      nxt.position.z = new_pos.z
      velocity.position = Point3.zero
      mob:set_in_free_motion(false)
   end

   -- Update our actual velocity and position.  Return false if we left
   -- the free motion state to get the task pruned
   mob:set_velocity(velocity);
   mob:set_transform(nxt);
   log:debug('%s new transform: %s  new velocity: %s', entity, nxt.position, velocity.position)

   return mob:get_in_free_motion()
end

function PhysicsService:_get_root_entity_container()
   return radiant._root_entity:add_component('entity_container')
end

return PhysicsService
