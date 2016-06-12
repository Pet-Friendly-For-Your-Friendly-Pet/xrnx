--[[============================================================================
xLib.xVoiceManager
============================================================================]]--

--[[--

This class keeps track of active, playing voices as they are triggered.
.
#

### In more detail

This class offers advanced voice-management for your own applications. This includes the ability to trigger and release specific instruments in specific tracks, while preserving the ability to freely move around in Renoise while doing so. 

Without voice-management it would be too easy to create hanging notes. Everything from switching track, instrument or octave while playing, to having multiple MIDI sources could cause trouble. A good voice-manager will understand this and be able to determine the originating 'place' where the voice got triggered. 

### Column allocation

The class is able to assist with automatic note-column allocation while recording. It's a basic approach, but close enough to how Renoise usually works to feel familiar. 

  * Recordings start from the currently selected note column 
  * New note columns (voices) are allocated as new notes arrive
  * Voices stay within their column as other voices are released/removed

### Polyphony limits

In Renoise, you can play a maximum of 12 voices in a single track (equal to the maximum number of note-columns). 

If you are familiar with MIDI recording in Renoise, you probably have noticed that there exist a monophonic trigger option. Enabling this option will restrict the number of possible voices (and note-columns) during a recording session. xVoiceManager has no "monophonic" mode as such, but setting the voice_limit to 1 will yield the same result. 

### Column allocation

When automatic column-allocation is enabled, new note columns are allocated as the need arises. When this feature is enabled, the polyphonic limit can never be larger than the number of available columns, starting from the column_index of the first voice. So if you start recording while in note-column 11, you have a maximum polyphony of 2 voices before voice stealing kicks in.

### Voice stealing

Voice stealing takes effect the moment you feed a xVoiceManager with more voices than the current polyphony limit allows. xVoiceManager is using a simple heuristic which will replace the oldest voice with the new one (just like how Renoise does it). 

### Observable events 

Attach notifiers to detect when voices are triggered or released. 

`triggered_observable` -> fired right *after* a voice starts playing  
`released_observable` -> fired right *before* a voice is released  

After you have attached a notifier, you will receive a 'bang', but no argument. Instead, you should look for the `triggered/released_index` properties - they will contain the value you need.

### Usage example

How to instantiate a copy of this class, and feed xMidiMessages into it:
	
    local voicemgr = xVoiceManager{
      follow_track = false,
    }
    
    voicemgr.triggered_observable:add_notifier(function()
      -- use 'voicemgr.triggered_index' 
    end)
    voicemgr.released_observable:add_notifier(function()
      -- use 'voicemgr.released_index'
    end)
    
    local xmsg = some_note_on_message -- provide your own message
    voicemgr:input_message(xmsg) -- should trigger our notifier



]]

--==============================================================================

class 'xVoiceManager'

xVoiceManager.EVENTS = {"released","triggered","stolen"}

xVoiceManager.EVENT = {
  RELEASED = "released",
  TRIGGERED = "triggered",
  STOLEN = "stolen",
}

function xVoiceManager:__init(...)

  local args = xLib.unpack_args(...)

  --- the maximum number of voices (0 = 'unlimited')
  self.voice_limit = property(self.get_voice_limit,self.set_voice_limit)
  self.voice_limit_observable = renoise.Document.ObservableNumber(args.voice_limit or 0)

  --- number, note duration in seconds (0 = infinite)
  self.duration = property(self.get_duration,self.set_duration)
  self.duration_observable = renoise.Document.ObservableNumber(args.duration or 0)

  --- bool, whether to use automatic column allocation or not
  self.column_allocation = property(self.get_column_allocation,self.set_column_allocation)
  self.column_allocation_observable = renoise.Document.ObservableBoolean(args.column_allocation or false)

  -- bool, set this value to true to avoid hanging notes while switching track
  self.follow_track = property(self.get_follow_track,self.set_follow_track)
  self.follow_track_observable = renoise.Document.ObservableBoolean(args.follow_track or true)

  -- bool, -//- switching instrument
  self.follow_instrument = property(self.get_follow_instrument,self.set_follow_instrument)
  self.follow_instrument_observable = renoise.Document.ObservableBoolean(args.follow_instrument or true)

  -- bool, -//- switching octave
  self.follow_octave = property(self.get_follow_octave,self.set_follow_octave)
  self.follow_octave_observable = renoise.Document.ObservableBoolean(args.follow_octave or true)

  -- events --

  --- voice about to be released (0 = none)
  self.released_index = 0
  self.released_observable = renoise.Document.ObservableBang()

  --- newly triggered voice (0 = none)
  self.triggered_index = 0
  self.triggered_observable = renoise.Document.ObservableBang()

  --- when voice got stolen (refer to released_index)
  self.stolen_index = 0
  self.stolen_observable = renoise.Document.ObservableBang()

  -- internal --

  --- table<xMidiMessage>, active voices
  self.voices = {}
  self.voices_observable = renoise.Document.ObservableNumberList()

  -- initialize

  renoise.tool().app_new_document_observable:add_notifier(function()
    rns = renoise.song()
    self:attach_to_song()
  end)

  renoise.tool().app_idle_observable:add_notifier(function()
    if (self.duration > 0) then
      self:check_expired()
    end
  end)

  self:attach_to_song()

end

--==============================================================================
-- Getters and setters 
--==============================================================================

function xVoiceManager:get_voice_limit()
  return self.voice_limit_observable.value
end

function xVoiceManager:set_voice_limit(val)

  -- if less than current #voices, release oldest ones first
  if (val < #self.voices) then
    for k = 1,(#self.voices-val) do
      self:release(k)
    end
  end

  self.voice_limit_observable.value = val

end

-------------------------------------------------------------------------------

function xVoiceManager:get_duration()
  return self.duration_observable.value
end

function xVoiceManager:set_duration(val)
  self.duration_observable.value = val
end

-------------------------------------------------------------------------------

function xVoiceManager:get_column_allocation()
  return self.column_allocation_observable.value
end

function xVoiceManager:set_column_allocation(val)
  self.column_allocation_observable.value = val
end

-------------------------------------------------------------------------------

function xVoiceManager:get_follow_track()
  return self.follow_track_observable.value
end

function xVoiceManager:set_follow_track(val)
  self.follow_track_observable.value = val
end

-------------------------------------------------------------------------------

function xVoiceManager:get_follow_instrument()
  return self.follow_instrument_observable.value
end

function xVoiceManager:set_follow_instrument(val)
  self.follow_instrument_observable.value = val
end

-------------------------------------------------------------------------------

function xVoiceManager:get_follow_octave()
  return self.follow_octave_observable.value
end

function xVoiceManager:set_follow_octave(val)
  self.follow_octave_observable.value = val
end


--==============================================================================
-- Class Methods
--==============================================================================
-- @param xmsg (xMidiMessage)
-- @return xMidiMessage (added/removed), false (ignored/active) or nil (invalid)
-- @return int (voice index), when added or active

function xVoiceManager:input_message(xmsg)
  TRACE("xVoiceManager:input_message(xmsg)",xmsg)

  assert(type(xmsg)=="xMidiMessage","Expected xmsg to be xMidiMessage")

  if (xmsg.message_type ~= xMidiMessage.TYPE.NOTE_ON) 
    and (xmsg.message_type ~= xMidiMessage.TYPE.NOTE_OFF) 
  then
    LOG("xVoiceManager - input_message() accepts note messages only ")
    return
  end

  local voice_idx = self:get_voice_index(xmsg)
  --print(">>> voice_idx",voice_idx)
  if voice_idx then
    if (xmsg.message_type == xMidiMessage.TYPE.NOTE_OFF) then
      local _xmsg = self.voices[voice_idx]
      _xmsg.message_type = xMidiMessage.TYPE.NOTE_OFF
      self:release(voice_idx)
      return _xmsg
    else
      LOG("*** xVoiceManager:input_message() - voice is already active")
      return false,voice_idx
    end
  end

  if (xmsg.message_type == xMidiMessage.TYPE.NOTE_OFF) then
    -- can end up here when releasing 'stolen' key 
    return 
  end

  -- add 'originating' properties? 

  if self.follow_track then
    xmsg._originating_track_index = xmsg.track_index
  end
  if self.follow_instrument then
    xmsg._originating_instrument_index = xmsg.instrument_index
  end
  if self.follow_octave then
    xmsg._originating_octave = xmsg.octave_index
  end

  self:register(xmsg)
  return xmsg,#self.voices

end

-------------------------------------------------------------------------------
-- register/add a voice

function xVoiceManager:register(xmsg)
  TRACE("xVoiceManager:register(xmsg)",xmsg)

  --print("self.column_allocation",self.column_allocation)

  if (self.voice_limit > 0) 
    and (#self.voices == self.voice_limit)
  then

    LOG("Steal the oldest voice and re-use that column")
    local steal_column_idx = self.voices[1].note_column_index
    self:steal_voice()
    xmsg.note_column_index = steal_column_idx

  elseif self.column_allocation then

    --print(">>> register - xmsg.note_column_index PRE",xmsg.note_column_index)
    local available_columns = self:get_available_columns(xmsg.track_index)
    --print("available_columns",rprint(available_columns))
    if not table.is_empty(available_columns) then
      -- use the incoming message's column if available
      local is_available = xmsg.note_column_index 
        and available_columns[xmsg.note_column_index] or false
      if is_available then
        --print("use the incoming message column",xmsg.note_column_index)
      else
        -- use the first available column, starting from current
        for k = xmsg.note_column_index,12 do
          if available_columns[k] then
            xmsg.note_column_index = k
            --print("first available column",k)
            break
          end
        end
      end
    else
      LOG("No more note columns available, using the last one")
      self:steal_voice()
      xmsg.note_column_index = 12
    end
    --print(">>> register - xmsg.note_column_index POST",xmsg.note_column_index)
  end

  table.insert(self.voices,xmsg)
  self.voices_observable:insert(#self.voices)

  -- trigger observable after adding
  self.triggered_index = #self.voices
  self.triggered_observable:bang()

end

-------------------------------------------------------------------------------
-- Release all active voices

function xVoiceManager:release_all()
  TRACE("xVoiceManager:release_all()")

  for k,v in ripairs(self.voices) do
    self:release(k)
    --print("released voice #",k)
  end

end

-------------------------------------------------------------------------------
-- Release all voices associated with a specific instrument

function xVoiceManager:release_all_instrument(instr_idx)
  TRACE("xVoiceManager:release_all_instrument(instr_idx)",instr_idx)

  for k,v in ripairs(self.voices) do
    if (v.instrument_index == instr_idx) then
      self:release(k)
    end
  end
end

-------------------------------------------------------------------------------
-- Release all voices associated with a specific track

function xVoiceManager:release_all_track(track_idx)
  TRACE("xVoiceManager:release_all_track(track_idx)",track_idx)

  for k,v in ripairs(self.voices) do
    if (v.track_index == track_idx) then
      self:release(k)
    end
  end
end

-------------------------------------------------------------------------------
-- release specific voice

function xVoiceManager:release(voice_idx)
  TRACE("xVoiceManager:release(voice_idx)",voice_idx)

  -- trigger observable before removing 
  -- (or we would not have access to voice details)
  self.released_index = voice_idx
  self.released_observable:bang()

  table.remove(self.voices,voice_idx)
  self.voices_observable:remove(voice_idx)

end

-------------------------------------------------------------------------------
-- check if any voices have expired (when duration is set)

function xVoiceManager:check_expired()
  --TRACE("xVoiceManager:check_expired()")

  for k,v in ripairs(self.voices) do
    local age = os.clock() - v.timestamp
    if (age > self.duration) then
      --print("release expired voice with age",age)
      self:release(k)
    end
  end

end

-------------------------------------------------------------------------------
-- locate among active voices, taking the pitch + track + instrument into
-- consideration (if all match, the voice is considered active...)
-- @param xmsg (xMidiMessage) should be a MIDI note-message
-- @return number or nil 

function xVoiceManager:get_voice_index(xmsg)
  TRACE("xVoiceManager:get_voice_index(xmsg)",xmsg)

  -- key events 
  if xmsg.message_type 
    and (xmsg.message_type ~= xMidiMessage.TYPE.NOTE_ON
    and xmsg.message_type ~= xMidiMessage.TYPE.NOTE_OFF
    and xmsg.message_type ~= xMidiMessage.TYPE.KEY_AFTERTOUCH)
  then
    LOG("*** xVoiceManager:input_message() - only MIDI notes and key-aftertouch are accepted")
    return
  end

  -- note/aftertouch, both are second byte
  local note = xmsg.values[1]

  -- on note-off, detect originating_XX  
  local _originating_instrument_index = nil
  local _originating_track_index = nil
  local _originating_octave = nil
  if (xmsg.message_type == xMidiMessage.TYPE.NOTE_OFF) then
    for k,v in ipairs(self.voices) do
      if (v.values[1] == note) then
        if not _originating_instrument_index 
          and self.follow_instrument 
          and v._originating_instrument_index 
        then
          _originating_instrument_index = v._originating_instrument_index
          print("v._originating_instrument_index",v._originating_instrument_index)
        end
        if not _originating_track_index
          and self.follow_track 
          and v._originating_track_index 
        then
          _originating_track_index = v._originating_track_index
          print("v._originating_track_index",v._originating_track_index)
        end
        if not _originating_octave
          and self.follow_octave 
          and v._originating_octave 
        then
          _originating_octave = v._originating_octave
          print("v._originating_octave",v._originating_octave)
        end
      end
    end
  end

  for k,v in ipairs(self.voices) do

    if (v.values[1] == note) then
      if xmsg.channel and (v.channel == xmsg.channel) 
        and xmsg.octave and ((v.octave == xmsg.octave) or (_originating_octave and v.octave == _originating_octave))
        and xmsg.track_index and ((v.track_index == xmsg.track_index) or (_originating_track_index and v.track_index == _originating_track_index))
        and xmsg.instrument_index and ((v.instrument_index == xmsg.instrument_index) or (_originating_instrument_index and v.instrument_index == _originating_instrument_index))
      then
        --print("matched voice",k)
        v.octave = _originating_octave or v.octave
        v.track_index = _originating_track_index or v.track_index
        v.instrument_index = _originating_instrument_index or v.instrument_index
        return k
      end
    end

  end

end

-------------------------------------------------------------------------------
-- @param track_idx
-- @return table

function xVoiceManager:get_available_columns(track_idx)

  local available_indices = {true,true,true,true,true,true,true,true,true,true,true,true}
  for k,v in ipairs(self.voices) do
    if (v.track_index == track_idx) then
      available_indices[v.note_column_index] = false
    end
  end
  return available_indices
end

-------------------------------------------------------------------------------
-- Release the oldest voice (release, then trigger stolen_observable)

function xVoiceManager:steal_voice()

  if (#self.voices < 0) then
    LOG("No active voice, nothing to steal...")
    return
  end

  self.stolen_index = 1
  self.stolen_observable:bang()

  self:release(self.stolen_index)


end

-------------------------------------------------------------------------------
-- Monitor changes to tracks and instruments

function xVoiceManager:attach_to_song()

  rns.instruments_observable:add_notifier(function(arg)
    TRACE("xVoiceManager: instruments_observable fired...",arg)

    if (arg.type == "remove") then
      self:release_all_instrument(arg.index)
    elseif (arg.type == "insert") then
      for k,v in ipairs(self.voices) do
        if (v.track_index >= arg.index) then
          v.track_index = v.track_index + 1
          --print("raise track index by 1")
        end
      end
    end

    --print("instruments_observable - self.voices...",rprint(self.voices))

  end)

  rns.tracks_observable:add_notifier(function(arg)
    TRACE("xVoiceManager: tracks_observable fired...",arg)

    if (arg.type == "remove") then
      self:release_all_track(arg.index)
    elseif (arg.type == "insert") then
      for k,v in ipairs(self.voices) do
        if (v.track_index >= arg.index) then
          v.track_index = v.track_index + 1
          --print("raise track index by 1")
        end
      end
    end

    --print("tracks_observable - self.voices...",rprint(self.voices))

  end)

end
