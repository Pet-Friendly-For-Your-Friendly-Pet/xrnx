-- -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
-- tool registration
-- -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

renoise.tool():add_menu_entry {
  name = "Pattern Editor:Pattern:Split...",
  invoke = function() 
     split()
  end
}

renoise.tool():add_keybinding {
  name = "Pattern Editor:Pattern:Split",
  invoke = function() split() end
}


-- -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
-- main content
-- -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

function split()

  local selected_line = renoise.song().selected_line;
  
  -- clone current pattern
  local new_pattern_index =    
    renoise.song().sequencer:clone_range(
      renoise.song().selected_sequence_index,
      renoise.song().selected_sequence_index);
    
  -- get the new pattern  
  local new_pattern = renoise.song().patterns[
    renoise.song().sequencer.pattern_sequence[
      renoise.song().selected_sequence_index + 1]];
      
  -- get the current pattern    
  local current_pattern = renoise.song().selected_pattern;
  
  -- get the ordinal number of the current line (where to split)
  local current_line = renoise.song().transport.edit_pos.line;
  
  -- cut the current pattern at that line
  current_pattern.number_of_lines = current_line; 
  
  -- dealing with automation.
  -- first of all, let's create an intermediate point between the last point of 
  -- previous pattern and the first of the new pattern, if it doesn't exists yet
  local num_tracks = table.getn(new_pattern.tracks);

  for num_track = 1, num_tracks do
    
    local current_pattern_track =  current_pattern.tracks[num_track]
    local new_pattern_track =  new_pattern.tracks[num_track]
    
    for num_auto = 1, table.getn(new_pattern_track.automation) do

      local current_automation = current_pattern_track.automation[num_auto]
      
      local new_automation = new_pattern_track.automation[num_auto]
      local new_points = new_automation.points
    
      -- let's see if the line on which we are cutting already has a point
      -- in the curve; in such case, we are lucky and don't need to add any
      -- intermediate point..
      if not new_automation:has_point_at(current_line) then
    
        -- let's see if the current automation curve has any point before the
        -- current_line and any point after current_line.
        local previous_point = 1
        local next_point = table.getn(new_points)

        for point = 1, table.getn(new_points) do
        
          if new_points[point].time < current_line and 
             previous_point < new_points[point].time 
          then
            -- get the highest line which is less than current_line
            previous_point = point
          end 
      
          if new_points[point].time > current_line and 
             next_point > new_points[point].time 
          then
            -- get the lowest line which is greater than current_line
            next_point = point				
          end
        end
      
        -- now create the transition point
        local transition_time = current_line
        local transition_value

        if previous_point == next_point then
          transition_value = new_points[previous_point].value
        else
          transition_value = 
            new_points[previous_point].value + 
            (new_points[next_point].value - new_points[previous_point].value) *
            (current_line - new_points[previous_point].time) /  
            (new_points[next_point].time - new_points[previous_point].time)
        end
          
        new_automation:add_point_at(current_line,transition_value)
        current_automation:add_point_at(current_line,transition_value)
  
      end
    
      -- delete any point which is before the current_line
      for point = 1, table.getn(new_points) do

        if new_points[point].time < current_line then
          new_automation:remove_point_at(new_points[point].time)
        end

      end
    
      -- refresh copy after deletion	
      new_points = new_automation.points
    
      -- shift back all the points after the current_line
      for point = 1, table.getn(new_points) do
      
        local auto_time = new_points[point].time - current_line + 1;
        local auto_value = new_points[point].value
      
        new_automation:remove_point_at(new_points[point].time)			
        new_automation:add_point_at(auto_time,auto_value)			
        point = point - 1
    
      end
  
    end
  
  end
  
  -- iterate through tracks of the new pattern to shift lines up
  for num_track = 1, num_tracks do
    
    for i = current_line + 1,new_pattern.number_of_lines do
       
      new_pattern.tracks[num_track]:line(i - current_line):copy_from(
         new_pattern.tracks[num_track]:line(i));
    
    end 
    
  end

  -- cut the new pattern
  new_pattern.number_of_lines = new_pattern.number_of_lines - current_line;
 
end