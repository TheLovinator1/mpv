--
-- frame-dumper.lua: An mpv script to save a range of frames as screenshots.
--
-- This script provides an interactive menu to select a start and end point in a
-- video and then exports each frame in that range as an individual image file.
--

local mp = require 'mp'
local utils = require 'mp.utils'

-- #############################################################################
-- # Platform-specific setup
-- #############################################################################
local is_windows = mp.get_property_native('platform') == 'win32'
local PATH_SEP = is_windows and '\\' or '/'

-- #############################################################################
-- # Configuration
-- #############################################################################
-- You can override these settings by creating a file named 'frame-dumper.conf'
-- in your 'script-opts' directory.
--
-- Example 'frame-dumper.conf':
--   key_toggle_menu=x
--   output_dir=C:\Users\YourUser\Pictures\mpv_exports
--
local opts = {
    -- The key to press to open and close the frame dumper menu.
    key_toggle_menu = "h",
    -- The directory where the screenshots will be saved.
    -- The script will attempt to create this directory if it doesn't exist.
    -- '~' will be expanded to your home directory.
    output_dir = "C:\\Screenshots\\mpv_exports",
    -- The file format for the output images (e.g., png, jpg, webp).
    output_format = "png"
}
local options = require 'mp.options'
options.read_options(opts)

-- #############################################################################
-- # Script State
-- #############################################################################

-- Holds the state of the menu and selections.
local S = {
    menu_active = false,
    overlay = nil,
    start_time = nil,
    end_time = nil
}

-- #############################################################################
-- # Helper Functions
-- #############################################################################

-- Expands paths that start with '~' to the user's home directory.
local function expand_path(path)
    if string.sub(path, 1, 1) == '~' then
        local home = os.getenv("HOME") or os.getenv("USERPROFILE")
        if home then
            return home .. string.sub(path, 2)
        end
    end
    return path
end

-- Ensures the output directory exists (creates parent directories as needed)
local function ensure_dir_exists(path)
    if is_windows then
        os.execute('mkdir "' .. path .. '"')
    else
        os.execute('mkdir -p "' .. path .. '"')
    end
end

-- #############################################################################
-- # Core Logic
-- #############################################################################

-- Updates the on-screen menu with the current status and instructions.
function update_menu_text()
    if not S.menu_active or not S.overlay then return end

    local start_str = S.start_time and string.format("%.3fs", S.start_time) or "Not set"
    local end_str = S.end_time and string.format("%.3fs", S.end_time) or "Not set"

    local text = "{\\an7\\b1\\fs28\\c&HFFFFFF&\\3c&H404040&}" -- Top-left, bold, white text with gray outline
    text = text .. "Frame Dumper Menu\\N\\N"
    text = text .. "{\\fs22}"
    text = text .. string.format("  Start Point: %s\\N", start_str)
    text = text .. string.format("  End Point:   %s\\N\\N", end_str)
    text = text .. "{\\b0}Controls:\\N"
    text = text .. "  [s]   - Mark current frame as START\\N"
    text = text .. "  [e]   - Mark current frame as END\\N"

    if S.start_time and S.end_time then
        text = text .. "  [d]   - DUMP frames between start and end\\N"
    end

    text = text .. string.format("  [%s] - Close this menu", opts.key_toggle_menu)

    S.overlay.data = text
    S.overlay:update()
end

-- The main function to perform the frame dumping.
function dump_frames()
    if not (S.start_time and S.end_time) then
        mp.osd_message("Error: Both start and end points must be set.")
        return
    end

    toggle_menu()

    local was_paused = mp.get_property_native("pause")
    mp.set_property("pause", "yes")

    mp.osd_message("Starting frame dump...", 3)

    local video_filename = mp.get_property("filename/no-ext") or "video"
    video_filename = string.gsub(video_filename, "[<>:\\/|?*%[%]]", "_")
    local output_path = expand_path(opts.output_dir)
    ensure_dir_exists(output_path)

    local selection_length = S.end_time - S.start_time
    local max_frames = 50
    local short_threshold = 2 -- seconds
    local use_every_frame = selection_length <= short_threshold
    local frame_step_time = use_every_frame and nil or selection_length / (max_frames - 1)

    mp.commandv("seek", S.start_time, "absolute", "exact")
    mp.add_timeout(0.2, function()
        local frame_count = 0
        local current_time = S.start_time
        while true do
            if not use_every_frame then
                mp.commandv("seek", current_time, "absolute", "exact")
            end
            local actual_time = mp.get_property_native("time-pos")
            if not actual_time or actual_time > S.end_time then
                break
            end
            local frame_num = mp.get_property_native("frame") or math.floor(actual_time * 1000)
            local filename = string.format("%s%s%s_frame_%07d.%s",
                                           output_path,
                                           PATH_SEP,
                                           video_filename,
                                           frame_num,
                                           opts.output_format)
            mp.commandv("screenshot-to-file", filename, "video")
            frame_count = frame_count + 1
            if use_every_frame then
                mp.commandv("frame-step")
                current_time = mp.get_property_native("time-pos")
            else
                current_time = current_time + frame_step_time
            end
            if frame_count >= max_frames or mp.get_property_native("eof-reached") then
                break
            end
        end
        mp.osd_message(string.format("Finished: Dumped %d frames to\n%s", frame_count, output_path), 5)
        if not was_paused then
            mp.set_property("pause", "no")
        end
        S.start_time = nil
        S.end_time = nil
    end)
end

-- #############################################################################
-- # Menu and Keybinding Handlers
-- #############################################################################

-- Toggles the menu visibility and sets/removes menu-specific keybindings.
function toggle_menu()
    S.menu_active = not S.menu_active
    if S.menu_active then
        -- Create overlay and bind menu keys.
        S.overlay = mp.create_osd_overlay()
        S.overlay.format = "ass-events"
        update_menu_text()
        mp.add_forced_key_binding("s", "dumper_mark_start", handle_mark_start)
        mp.add_forced_key_binding("e", "dumper_mark_end", handle_mark_end)
        mp.add_forced_key_binding("d", "dumper_dump", dump_frames)
        mp.osd_message("Frame Dumper Menu: ON")
    else
        -- Remove overlay and unbind menu keys.
        if S.overlay then
            S.overlay:remove()
            S.overlay = nil
        end
        mp.remove_key_binding("dumper_mark_start")
        mp.remove_key_binding("dumper_mark_end")
        mp.remove_key_binding("dumper_dump")
        mp.osd_message("Frame Dumper Menu: OFF")
    end
end

-- Handles the 'mark start' action from the menu.
function handle_mark_start()
    if not S.menu_active then return end
    S.start_time = mp.get_property_native("time-pos")
    -- If end is before new start, reset end.
    if S.end_time and S.end_time <= S.start_time then
        S.end_time = nil
    end
    update_menu_text()
end

-- Handles the 'mark end' action from the menu.
function handle_mark_end()
    if not S.menu_active then return end
    local current_time = mp.get_property_native("time-pos")
    if S.start_time and current_time <= S.start_time then
        mp.osd_message("Error: End point must be after the start point.", 2)
    else
        S.end_time = current_time
        update_menu_text()
    end
end

-- Register the primary keybinding to activate the script.
mp.add_key_binding(opts.key_toggle_menu, "toggle_frame_dumper", toggle_menu)
mp.osd_message("Frame Dumper: Keybinding '" .. opts.key_toggle_menu .. "' registered.", 2)
print("Frame Dumper: Keybinding '" .. opts.key_toggle_menu .. "' registered.")

print("Frame Dumper script loaded.")
