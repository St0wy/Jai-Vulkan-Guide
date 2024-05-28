
ImGui_ImplSDL2_InitForVulkan :: (window: *SDL_Window) -> bool
{
	if (!ImGui_ImplSDL2_Init(window, null, null))
        return false;
    bd := ImGui_ImplSDL2_GetBackendData();
    bd.UseVulkan = true;
    return true;
}

ImGui_ImplSDL2_Shutdown :: ()
{
	bd := ImGui_ImplSDL2_GetBackendData();
	assert(bd != null, "No platform backend to shutdown, or already shutdown?");
	io := ImGui.GetIO();
	platform_io := ImGui.GetPlatformIO();
	
	ImGui_ImplSDL2_ShutdownPlatformInterface();
	
	if bd.ClipboardTextData then SDL_free(bd.ClipboardTextData);
	
	for i: 0..ImGui.MouseCursor.COUNT - 1 SDL_FreeCursor(bd.MouseCursors[i]);
	
	io.BackendPlatformName = null;
    io.BackendPlatformUserData = null;
    io.BackendFlags_ &= ~(
    	.HasMouseCursors | 
    	.HasSetMousePos | 
    	.HasGamepad | 
    	.PlatformHasViewports | 
    	.HasMouseHoveredViewport
    );
    free(bd);
}

ImGui_ImplSDL2_NewFrame :: ()
{
	bd := ImGui_ImplSDL2_GetBackendData();
	assert(bd != null, "Context or backend not initialized! Did you call ImGui_ImplSDL2_Init()?");
	io := ImGui.GetIO();
	
	w, h: s32;
	display_w, display_h: s32;
	
	SDL_GetWindowSize(bd.Window, *w, *h);
	if SDL_GetWindowFlags(bd.Window) & .SDL_WINDOW_MINIMIZED
	{
		w = 0;
		h = 0;
	}
	
	if bd.Renderer != null
		SDL_GetRendererOutputSize(bd.Renderer, *display_w, *display_h);
	else
		SDL_GL_GetDrawableSize(bd.Window, *display_w, *display_h);
		
	io.DisplaySize = ImGui.ImVec2.{cast(float32) w, cast(float32) h};
	
	if w > 0 && h > 0
		io.DisplayFramebufferScale = ImGui.ImVec2.{
			cast(float32) display_w / w, cast(float32) display_h / h};
	
	if bd.WantUpdateMonitors then ImGui_ImplSDL2_UpdateMonitors();
	
	frequency := SDL_GetPerformanceFrequency();
	current_time := SDL_GetPerformanceCounter();
	if current_time <= bd.Time
		current_time = bd.Time + 1;
	io.DeltaTime = ifx bd.Time > 0
	{
		cast(float32)(cast(float64)(current_time - bd.Time) / frequency);
	}
	else
	{
		cast(float32) (1.0 / 60);
	}
	
	bd.Time = current_time;
	
	if bd.MouseLastLeaveFrame && bd.MouseLastLeaveFrame >= ImGui.GetFrameCount() && bd.MouseButtonsDown == 0
	{
		bd.MouseWindowID = 0;
		bd.MouseLastLeaveFrame = 0;
		io.AddMousePosEvent(io, -FLOAT32_MAX, -FLOAT32_MAX);
	}
	
	if bd.MouseCanReportHoveredViewport && ImGui.GetDragDropPayload() == null
		io.BackendFlags_ |= .HasMouseHoveredViewport;
	else
		io.BackendFlags_ &= ~.HasMouseHoveredViewport;
		
	ImGui_ImplSDL2_UpdateMouseData();
    ImGui_ImplSDL2_UpdateMouseCursor();

    // Update game controllers (if enabled and available)
    ImGui_ImplSDL2_UpdateGamepads();
}

ImGui_ImplSDL2_ProcessEvent :: (event: *SDL_Event) -> bool
{
	
    bd := ImGui_ImplSDL2_GetBackendData();
    assert(bd != null, "Context or backend not initialized! Did you call ImGui_ImplSDL2_Init()?");
    io := ImGui.GetIO();

    if event.type ==
    {
        case SDL_MOUSEMOTION;
        {
            mouse_pos := ImGui.ImVec2.{cast(float32)event.motion.x, cast(float32)event.motion.y};
            if (io.ConfigFlags_ & .ViewportsEnable)
            {
                window_x, window_y: s32;
                SDL_GetWindowPosition(SDL_GetWindowFromID(event.motion.windowID), *window_x, *window_y);
                mouse_pos.x += window_x;
                mouse_pos.y += window_y;
            }
            io.AddMouseSourceEvent(io, .Mouse);
            io.AddMousePosEvent(io, mouse_pos.x, mouse_pos.y);
            return true;
        }
        case SDL_MOUSEWHEEL;
        {
            wheel_x := -event.wheel.preciseX;
            wheel_y := event.wheel.preciseY;

            io.AddMouseSourceEvent(io, .Mouse);
            io.AddMouseWheelEvent(io, wheel_x, wheel_y);
            return true;
        }
        case SDL_MOUSEBUTTONDOWN; #through;
        case SDL_MOUSEBUTTONUP;
        {
            mouse_button: s32= -1;
            if (event.button.button == SDL_BUTTON_LEFT) { mouse_button = 0; }
            if (event.button.button == SDL_BUTTON_RIGHT) { mouse_button = 1; }
            if (event.button.button == SDL_BUTTON_MIDDLE) { mouse_button = 2; }
            if (event.button.button == SDL_BUTTON_X1) { mouse_button = 3; }
            if (event.button.button == SDL_BUTTON_X2) { mouse_button = 4; }
            if (mouse_button == -1)
                return false;
            io.AddMouseSourceEvent(io, .Mouse);
            io.AddMouseButtonEvent(io, mouse_button, (event.type == SDL_MOUSEBUTTONDOWN));
            bd.MouseButtonsDown = xx ifx (event.type == SDL_MOUSEBUTTONDOWN) then (bd.MouseButtonsDown | (1 << mouse_button)) else (bd.MouseButtonsDown & ~(1 << mouse_button));
            return true;
        }
        case SDL_TEXTINPUT;
        {
            io.AddInputCharactersUTF8(io, cast(*u8) event.text.text.data);
            return true;
        }
        case SDL_KEYDOWN; #through;
        case SDL_KEYUP;
        {
            ImGui_ImplSDL2_UpdateKeyModifiers(cast(SDL_Keymod)event.key.keysym.mod);
            key := ImGui_ImplSDL2_KeycodeToImGuiKey(event.key.keysym.sym);
            io.AddKeyEvent(io, key, (event.type == SDL_KEYDOWN));
            // To support legacy indexing (<1.87 user code). Legacy backend uses SDLK_*** as indices to IsKeyXXX() functions.
            io.SetKeyEventNativeData(io, key, cast(s32) event.key.keysym.sym, cast(s32) event.key.keysym.scancode, cast(s32) event.key.keysym.scancode); 
            return true;
        }
        case SDL_DISPLAYEVENT;
        {
            // 2.0.26 has SDL_DISPLAYEVENT_CONNECTED/SDL_DISPLAYEVENT_DISCONNECTED/SDL_DISPLAYEVENT_ORIENTATION,
            // so change of DPI/Scaling are not reflected in this event. (SDL3 has it)
            bd.WantUpdateMonitors = true;
            return true;
        }
        case SDL_WINDOWEVENT;
        {
            // - When capturing mouse, SDL will send a bunch of conflicting LEAVE/ENTER event on every mouse move, but the final ENTER tends to be right.
            // - However we won't get a correct LEAVE event for a captured window.
            // - In some cases, when detaching a window from main viewport SDL may send SDL_WINDOWEVENT_ENTER one frame too late,
            //   causing SDL_WINDOWEVENT_LEAVE on previous frame to interrupt drag operation by clear mouse position. This is why
            //   we delay process the SDL_WINDOWEVENT_LEAVE events by one frame. See issue #5012 for details.
            window_event := event.window.event;
            if (window_event == SDL_WINDOWEVENT_ENTER)
            {
                bd.MouseWindowID = event.window.windowID;
                bd.MouseLastLeaveFrame = 0;
            }
            
            if (window_event == SDL_WINDOWEVENT_LEAVE)
                bd.MouseLastLeaveFrame = ImGui.GetFrameCount() + 1;
            if (window_event == SDL_WINDOWEVENT_FOCUS_GAINED)
                io.AddFocusEvent(io, true);
            else if (window_event == SDL_WINDOWEVENT_FOCUS_LOST)
                io.AddFocusEvent(io, false);
            if (window_event == SDL_WINDOWEVENT_CLOSE || window_event == SDL_WINDOWEVENT_MOVED || window_event == SDL_WINDOWEVENT_RESIZED)
            {
            	viewport := ImGui.FindViewportByPlatformHandle(cast(*void)SDL_GetWindowFromID(event.window.windowID));
                if (viewport)
                {
                    if (window_event == SDL_WINDOWEVENT_CLOSE)
                        viewport.PlatformRequestClose = true;
                    if (window_event == SDL_WINDOWEVENT_MOVED)
                        viewport.PlatformRequestMove = true;
                    if (window_event == SDL_WINDOWEVENT_RESIZED)
                        viewport.PlatformRequestResize = true;
                    return true;
                }
            }	
            return true;
        }
        case SDL_CONTROLLERDEVICEADDED; #through;
        case SDL_CONTROLLERDEVICEREMOVED;
        {
            bd.WantUpdateGamepadsList = true;
            return true;
        }
    }
    return false;
}

ImGui_ImplSDL2_GamepadMode :: enum
{
	AutoFirst;
	AutoAll;
	Manual;
}

ImGui_ImplSDL2_SetGamepadMode :: (
	mode: ImGui_ImplSDL2_GamepadMode, 
	manual_gamepads_array: **SDL_GameController = null, 
	manual_gamepads_count: s32 = -1
)
{
	bd := ImGui_ImplSDL2_GetBackendData();
	ImGui_ImplSDL2_CloseGamepads();
	if mode == .Manual
	{
		assert(manual_gamepads_array != null && manual_gamepads_count > 0);
		for i: 0..manual_gamepads_count - 1
			ImGui.vector_push_back(*bd.Gamepads, manual_gamepads_array[i]);
	}
	else
	{
		assert(manual_gamepads_array == null && manual_gamepads_count <= 0);
		bd.WantUpdateGamepadsList = true;
	}
	
	bd.GamepadMode = mode;
}

#scope_file

// In C++ this is defined as : 
//	#if SDL_VERSION_ATLEAST(2, 0, 4) && !defined(__EMSCRIPTEN__) && \
//	!defined(__ANDROID__) && !(defined(__APPLE__) && TARGET_OS_IOS) && \
//	!defined(__amigaos4__)
//	#define SDL_HAS_CAPTURE_AND_GLOBAL_MOUSE 1
//	#else
//	#define SDL_HAS_CAPTURE_AND_GLOBAL_MOUSE 0
//	#endif
SDL_HAS_CAPTURE_AND_GLOBAL_MOUSE :: OS != .ANDROID && OS != .MACOS;

ImGui_ImplSDL2_Data :: struct
{
	Window: *SDL_Window;
	Renderer: *SDL_Renderer;
	Time: u64;
	ClipboardTextData: *u8;
	UseVulkan: bool;
	WantUpdateMonitors: bool;
	
	// Mouse handling
	MouseWindowID: u32;
	MouseButtonsDown: s32;
	MouseCursors: [ImGui.MouseCursor.COUNT] *SDL_Cursor;
	MouseLastCursor: *SDL_Cursor;
	MouseLastLeaveFrame: s32;
	MouseCanUseGlobalState: bool;
	MouseCanReportHoveredViewport: bool;
	
	// Gamepad handling
	Gamepads: ImGui.ImVector(*SDL_GameController);
	GamepadMode: ImGui_ImplSDL2_GamepadMode;
	WantUpdateGamepadsList: bool;
}

ImGui_ImplSDL2_GetBackendData :: () -> *ImGui_ImplSDL2_Data #c_call
{
	return ifx ImGui.GetCurrentContext()
	{
		cast(*ImGui_ImplSDL2_Data)ImGui.GetIO().BackendPlatformUserData;
	}
	else
	{
		null;
	};
}

ImGui_ImplSDL2_GetClipboardText :: (_: *void) -> *u8 #c_call
{
	bd := ImGui_ImplSDL2_GetBackendData();
    if bd.ClipboardTextData then SDL_free(bd.ClipboardTextData);
    bd.ClipboardTextData = SDL_GetClipboardText();
    return bd.ClipboardTextData;
}

ImGui_ImplSDL2_SetClipboardText :: (_: *void, text: *u8) #c_call
{
	SDL_SetClipboardText(text);
}

ImGui_ImplSDL2_SetPlatformImeData :: (viewport: *ImGui.Viewport, data: *ImGui.PlatformImeData) #c_call
{
	if !data.WantVisible then return;
	
	r: SDL_Rect;
	r.x = cast(s32)(data.InputPos.x - viewport.Pos.x);
    r.y = cast(s32)(data.InputPos.y - viewport.Pos.y + data.InputLineHeight);
    r.w = 1;
    r.h = cast(s32)data.InputLineHeight;
    SDL_SetTextInputRect(*r);
}

ImGui_ImplSDL2_KeycodeToImGuiKey :: (keycode: SDL_Keycode) -> ImGui.Key
{
	if keycode == 
    {
        case SDLK_TAB; return .ImGuiKey_Tab;
        case SDLK_LEFT; return .ImGuiKey_LeftArrow;
        case SDLK_RIGHT; return .ImGuiKey_RightArrow;
        case SDLK_UP; return .ImGuiKey_UpArrow;
        case SDLK_DOWN; return .ImGuiKey_DownArrow;
        case SDLK_PAGEUP; return .ImGuiKey_PageUp;
        case SDLK_PAGEDOWN; return .ImGuiKey_PageDown;
        case SDLK_HOME; return .ImGuiKey_Home;
        case SDLK_END; return .ImGuiKey_End;
        case SDLK_INSERT; return .ImGuiKey_Insert;
        case SDLK_DELETE; return .ImGuiKey_Delete;
        case SDLK_BACKSPACE; return .ImGuiKey_Backspace;
        case SDLK_SPACE; return .ImGuiKey_Space;
        case SDLK_RETURN; return .ImGuiKey_Enter;
        case SDLK_ESCAPE; return .ImGuiKey_Escape;
        case SDLK_QUOTE; return .ImGuiKey_Apostrophe;
        case SDLK_COMMA; return .ImGuiKey_Comma;
        case SDLK_MINUS; return .ImGuiKey_Minus;
        case SDLK_PERIOD; return .ImGuiKey_Period;
        case SDLK_SLASH; return .ImGuiKey_Slash;
        case SDLK_SEMICOLON; return .ImGuiKey_Semicolon;
        case SDLK_EQUALS; return .ImGuiKey_Equal;
        case SDLK_LEFTBRACKET; return .ImGuiKey_LeftBracket;
        case SDLK_BACKSLASH; return .ImGuiKey_Backslash;
        case SDLK_RIGHTBRACKET; return .ImGuiKey_RightBracket;
        case SDLK_BACKQUOTE; return .ImGuiKey_GraveAccent;
        case SDLK_CAPSLOCK; return .ImGuiKey_CapsLock;
        case SDLK_SCROLLLOCK; return .ImGuiKey_ScrollLock;
        case SDLK_NUMLOCKCLEAR; return .ImGuiKey_NumLock;
        case SDLK_PRINTSCREEN; return .ImGuiKey_PrintScreen;
        case SDLK_PAUSE; return .ImGuiKey_Pause;
        case SDLK_KP_0; return .ImGuiKey_Keypad0;
        case SDLK_KP_1; return .ImGuiKey_Keypad1;
        case SDLK_KP_2; return .ImGuiKey_Keypad2;
        case SDLK_KP_3; return .ImGuiKey_Keypad3;
        case SDLK_KP_4; return .ImGuiKey_Keypad4;
        case SDLK_KP_5; return .ImGuiKey_Keypad5;
        case SDLK_KP_6; return .ImGuiKey_Keypad6;
        case SDLK_KP_7; return .ImGuiKey_Keypad7;
        case SDLK_KP_8; return .ImGuiKey_Keypad8;
        case SDLK_KP_9; return .ImGuiKey_Keypad9;
        case SDLK_KP_PERIOD; return .ImGuiKey_KeypadDecimal;
        case SDLK_KP_DIVIDE; return .ImGuiKey_KeypadDivide;
        case SDLK_KP_MULTIPLY; return .ImGuiKey_KeypadMultiply;
        case SDLK_KP_MINUS; return .ImGuiKey_KeypadSubtract;
        case SDLK_KP_PLUS; return .ImGuiKey_KeypadAdd;
        case SDLK_KP_ENTER; return .ImGuiKey_KeypadEnter;
        case SDLK_KP_EQUALS; return .ImGuiKey_KeypadEqual;
        case SDLK_LCTRL; return .ImGuiKey_LeftCtrl;
        case SDLK_LSHIFT; return .ImGuiKey_LeftShift;
        case SDLK_LALT; return .ImGuiKey_LeftAlt;
        case SDLK_LGUI; return .ImGuiKey_LeftSuper;
        case SDLK_RCTRL; return .ImGuiKey_RightCtrl;
        case SDLK_RSHIFT; return .ImGuiKey_RightShift;
        case SDLK_RALT; return .ImGuiKey_RightAlt;
        case SDLK_RGUI; return .ImGuiKey_RightSuper;
        case SDLK_APPLICATION; return .ImGuiKey_Menu;
        case SDLK_0; return .ImGuiKey_0;
        case SDLK_1; return .ImGuiKey_1;
        case SDLK_2; return .ImGuiKey_2;
        case SDLK_3; return .ImGuiKey_3;
        case SDLK_4; return .ImGuiKey_4;
        case SDLK_5; return .ImGuiKey_5;
        case SDLK_6; return .ImGuiKey_6;
        case SDLK_7; return .ImGuiKey_7;
        case SDLK_8; return .ImGuiKey_8;
        case SDLK_9; return .ImGuiKey_9;
        case SDLK_a; return .ImGuiKey_A;
        case SDLK_b; return .ImGuiKey_B;
        case SDLK_c; return .ImGuiKey_C;
        case SDLK_d; return .ImGuiKey_D;
        case SDLK_e; return .ImGuiKey_E;
        case SDLK_f; return .ImGuiKey_F;
        case SDLK_g; return .ImGuiKey_G;
        case SDLK_h; return .ImGuiKey_H;
        case SDLK_i; return .ImGuiKey_I;
        case SDLK_j; return .ImGuiKey_J;
        case SDLK_k; return .ImGuiKey_K;
        case SDLK_l; return .ImGuiKey_L;
        case SDLK_m; return .ImGuiKey_M;
        case SDLK_n; return .ImGuiKey_N;
        case SDLK_o; return .ImGuiKey_O;
        case SDLK_p; return .ImGuiKey_P;
        case SDLK_q; return .ImGuiKey_Q;
        case SDLK_r; return .ImGuiKey_R;
        case SDLK_s; return .ImGuiKey_S;
        case SDLK_t; return .ImGuiKey_T;
        case SDLK_u; return .ImGuiKey_U;
        case SDLK_v; return .ImGuiKey_V;
        case SDLK_w; return .ImGuiKey_W;
        case SDLK_x; return .ImGuiKey_X;
        case SDLK_y; return .ImGuiKey_Y;
        case SDLK_z; return .ImGuiKey_Z;
        case SDLK_F1; return .ImGuiKey_F1;
        case SDLK_F2; return .ImGuiKey_F2;
        case SDLK_F3; return .ImGuiKey_F3;
        case SDLK_F4; return .ImGuiKey_F4;
        case SDLK_F5; return .ImGuiKey_F5;
        case SDLK_F6; return .ImGuiKey_F6;
        case SDLK_F7; return .ImGuiKey_F7;
        case SDLK_F8; return .ImGuiKey_F8;
        case SDLK_F9; return .ImGuiKey_F9;
        case SDLK_F10; return .ImGuiKey_F10;
        case SDLK_F11; return .ImGuiKey_F11;
        case SDLK_F12; return .ImGuiKey_F12;
        case SDLK_F13; return .ImGuiKey_F13;
        case SDLK_F14; return .ImGuiKey_F14;
        case SDLK_F15; return .ImGuiKey_F15;
        case SDLK_F16; return .ImGuiKey_F16;
        case SDLK_F17; return .ImGuiKey_F17;
        case SDLK_F18; return .ImGuiKey_F18;
        case SDLK_F19; return .ImGuiKey_F19;
        case SDLK_F20; return .ImGuiKey_F20;
        case SDLK_F21; return .ImGuiKey_F21;
        case SDLK_F22; return .ImGuiKey_F22;
        case SDLK_F23; return .ImGuiKey_F23;
        case SDLK_F24; return .ImGuiKey_F24;
        case SDLK_AC_BACK; return .ImGuiKey_AppBack;
        case SDLK_AC_FORWARD; return .ImGuiKey_AppForward;
    }
    return .ImGuiKey_None;
}

ImGui_ImplSDL2_UpdateKeyModifiers :: (sdl_key_mods: SDL_Keymod)
{
	io := ImGui.GetIO();
	io.AddKeyEvent(io, ImGui.Key.Mod_Ctrl, (sdl_key_mods & KMOD_CTRL) != 0);
    io.AddKeyEvent(io, ImGui.Key.Mod_Shift, (sdl_key_mods & KMOD_SHIFT) != 0);
    io.AddKeyEvent(io, ImGui.Key.Mod_Alt, (sdl_key_mods & KMOD_ALT) != 0);
    io.AddKeyEvent(io, ImGui.Key.Mod_Super, (sdl_key_mods & KMOD_GUI) != 0);
}

ImGui_ImplSDL2_Init :: (window: *SDL_Window, renderer: *SDL_Renderer, sdl_gl_context: *void) -> bool
{
	io := ImGui.GetIO();
	assert(io.BackendPlatformUserData == null, "Already initialized a platform backend!");
	
	mouse_can_use_global_state := false;
	
	#if SDL_HAS_CAPTURE_AND_GLOBAL_MOUSE
	{
		sdl_backend := SDL_GetCurrentVideoDriver();
		global_mouse_whitelist :: (*u8).["windows\0", "cocoa\0", "x11\0", "DIVE\0", "VMAN\0"];
		
		for global_mouse_whitelist
		{
			if strcmp(sdl_backend, it) == 0 then mouse_can_use_global_state = true;
		}
	}
	
	bd := New(ImGui_ImplSDL2_Data);
	io.BackendPlatformUserData = cast(*void)bd;
  	io.BackendPlatformName = "imgui_impl_sdl2";
  	io.BackendFlags_ |= .HasMouseCursors; 
  	io.BackendFlags_ |= .HasSetMousePos; 
  	
	if (mouse_can_use_global_state)
	{
		io.BackendFlags_ |= .PlatformHasViewports;
	}
	
	bd.Window = window;
	bd.Renderer = renderer;
	
	bd.MouseCanUseGlobalState = mouse_can_use_global_state;
	
	#if OS == .MACOS
	{
		bd.MouseCanReportHoveredViewport = bd.MouseCanUseGlobalState;
	}
	else
	{
		bd.MouseCanReportHoveredViewport = false;
	}
	
	bd.WantUpdateMonitors = true;
	
	io.SetClipboardTextFn = ImGui_ImplSDL2_SetClipboardText;
    io.GetClipboardTextFn = ImGui_ImplSDL2_GetClipboardText;
    io.ClipboardUserData = null;
    io.SetPlatformImeDataFn = ImGui_ImplSDL2_SetPlatformImeData;
    
    bd.GamepadMode = .AutoFirst;
    bd.WantUpdateGamepadsList = true;
    
    bd.MouseCursors[ImGui.MouseCursor.Arrow] = SDL_CreateSystemCursor(.ARROW);
    bd.MouseCursors[ImGui.MouseCursor.TextInput] = SDL_CreateSystemCursor(.IBEAM);
    bd.MouseCursors[ImGui.MouseCursor.ResizeAll] = SDL_CreateSystemCursor(.SIZEALL);
    bd.MouseCursors[ImGui.MouseCursor.ResizeNS] = SDL_CreateSystemCursor(.SIZENS);
    bd.MouseCursors[ImGui.MouseCursor.ResizeEW] = SDL_CreateSystemCursor(.SIZEWE);
    bd.MouseCursors[ImGui.MouseCursor.ResizeNESW] = SDL_CreateSystemCursor(.SIZENESW);
    bd.MouseCursors[ImGui.MouseCursor.ResizeNWSE] = SDL_CreateSystemCursor(.SIZENWSE);
    bd.MouseCursors[ImGui.MouseCursor.Hand] = SDL_CreateSystemCursor(.HAND);
    bd.MouseCursors[ImGui.MouseCursor.NotAllowed] = SDL_CreateSystemCursor(.NO);
    
    main_viewport := ImGui.GetMainViewport();
    main_viewport.PlatformHandle = cast(*void) window;
    main_viewport.PlatformHandleRaw = null;
    
    info: SDL_SysWMinfo;
    SDL_VERSION(*info.version);
    
    if SDL_GetWindowWMInfo(window, *info)
    {
    	#if OS == .WINDOWS
    		main_viewport.PlatformHandleRaw = cast(*void)info.info.win.window;
    }
    
    SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
    // These hints are not set in the SDL bindings, maybe I should add them
    // but IDK if the version has it
	// SDL_SetHint(SDL_HINT_IME_SHOW_UI, "1");
	// SDL_SetHint(SDL_HINT_MOUSE_AUTO_CAPTURE, "0");
	
	// TODO Add that once and if viewports functions are done
	// if (io.ConfigFlags_ & .ViewportsEnable) && (io.BackendFlags_ & .PlatformHasViewports)
	//     ImGui_ImplSDL2_InitPlatformInterface(window, sdl_gl_context);
	
	return true;
}

ImGui_ImplSDL2_InitPlatformInterface :: (window: *SDL_Window, sdl_gl_context: *void)
{
	// TODO Add that once and if viewports functions are done
	// 	ImGuiPlatformIO& platform_io = ImGui::GetPlatformIO();
	//     platform_io.Platform_CreateWindow = ImGui_ImplSDL2_CreateWindow;
	//     platform_io.Platform_DestroyWindow = ImGui_ImplSDL2_DestroyWindow;
	//     platform_io.Platform_ShowWindow = ImGui_ImplSDL2_ShowWindow;
	//     platform_io.Platform_SetWindowPos = ImGui_ImplSDL2_SetWindowPos;
	//     platform_io.Platform_GetWindowPos = ImGui_ImplSDL2_GetWindowPos;
	//     platform_io.Platform_SetWindowSize = ImGui_ImplSDL2_SetWindowSize;
	//     platform_io.Platform_GetWindowSize = ImGui_ImplSDL2_GetWindowSize;
	//     platform_io.Platform_SetWindowFocus = ImGui_ImplSDL2_SetWindowFocus;
	//     platform_io.Platform_GetWindowFocus = ImGui_ImplSDL2_GetWindowFocus;
	//     platform_io.Platform_GetWindowMinimized = ImGui_ImplSDL2_GetWindowMinimized;
	//     platform_io.Platform_SetWindowTitle = ImGui_ImplSDL2_SetWindowTitle;
	//     platform_io.Platform_RenderWindow = ImGui_ImplSDL2_RenderWindow;
	//     platform_io.Platform_SwapBuffers = ImGui_ImplSDL2_SwapBuffers;
	// #if SDL_HAS_WINDOW_ALPHA
	//     platform_io.Platform_SetWindowAlpha = ImGui_ImplSDL2_SetWindowAlpha;
	// #endif
	// #if SDL_HAS_VULKAN
	//     platform_io.Platform_CreateVkSurface = ImGui_ImplSDL2_CreateVkSurface;
	// #endif

	//     // Register main window handle (which is owned by the main application, not by us)
	// // This is mostly for simplicity and consistency, so that our code (e.g. mouse handling etc.) can use same logic for main and secondary viewports.
	// ImGuiViewport* main_viewport = ImGui::GetMainViewport();
	// ImGui_ImplSDL2_ViewportData* vd = IM_NEW(ImGui_ImplSDL2_ViewportData)();
	// vd->Window = window;
	// vd->WindowID = SDL_GetWindowID(window);
	// vd->WindowOwned = false;
	// vd->GLContext = sdl_gl_context;
	// main_viewport->PlatformUserData = vd;
	// main_viewport->PlatformHandle = vd->Window;
}

ImGui_ImplSDL2_ShutdownPlatformInterface :: ()
{
	ImGui.DestroyPlatformWindows();
}

ImGui_ImplSDL2_UpdateMouseData :: ()
{
	bd := ImGui_ImplSDL2_GetBackendData();
	io := ImGui.GetIO();
	
	#if SDL_HAS_CAPTURE_AND_GLOBAL_MOUSE
	{
		SDL_CaptureMouse(ifx bd.MouseButtonsDown != 0 then SDL_TRUE else SDL_FALSE);
		focused_window := SDL_GetKeyboardFocus();
		if focused_window then bd.Window = focused_window;
		is_app_focused := 
			focused_window && 
			(bd.Window || 
			ImGui.FindViewportByPlatformHandle(cast(*void) focused_window));
	}
	else
	{
		focused_window := bd.Window;
		is_app_focused := SDL_GetWindowFlags(bd.Window) & SDL_WINDOW_INPUT_FOCUS != 0;
	}
	
	if is_app_focused
	{
		if io.WantSetMousePos
		{
			#if SDL_HAS_CAPTURE_AND_GLOBAL_MOUSE
			{
				if io.ConfigFlags_ & .ViewportsEnable
				{
					SDL_WarpMouseGlobal(xx io.MousePos.x, xx io.MousePos.y);
				}
				else
				{
					SDL_WarpMouseInWindow(bd.Window, xx io.MousePos.x, xx io.MousePos.y);
				}
			}
			else
			{
				SDL_WarpMouseInWindow(bd.Window, xx io.MousePos.x, xx io.MousePos.y);
			}
		}
		
		if bd.MouseCanUseGlobalState && bd.MouseButtonsDown == 0
		{
			mouse_x, mouse_y, window_x, window_y: s32;
			SDL_GetGlobalMouseState(*mouse_x, *mouse_y);
			
			if !(io.ConfigFlags_ & .ViewportsEnable)
			{
				SDL_GetWindowPosition(focused_window, *window_x, *window_y);
				mouse_x -= window_x;
				mouse_y -= window_y;
			}
			
			io.AddMousePosEvent(io, cast(float32) mouse_x, cast(float32) mouse_y);
		}
	}
	
	if io.BackendFlags_ & .HasMouseHoveredViewport
	{
		mouse_viewport_id: ImGui.ID = 0;
		sdl_mouse_window := SDL_GetWindowFromID(bd.MouseWindowID);
		if sdl_mouse_window
		{
			mouse_viewport := ImGui.FindViewportByPlatformHandle(cast(*void) sdl_mouse_window);
			if mouse_viewport
			{
				mouse_viewport_id = mouse_viewport.ID_;
				io.AddMouseViewportEvent(io, mouse_viewport_id);
			}
		}
	}
}

ImGui_ImplSDL2_UpdateMouseCursor :: ()
{
	io := ImGui.GetIO();
	if io.ConfigFlags_ & .NoMouseCursorChange then return;
	
	bd := ImGui_ImplSDL2_GetBackendData();
	imgui_cursor := ImGui.GetMouseCursor();
	if io.MouseDrawCursor || imgui_cursor == .None
	{
		SDL_ShowCursor(xx SDL_FALSE);
	}
	else
	{
		expected_cursor := ifx bd.MouseCursors[imgui_cursor] then
		{
			bd.MouseCursors[imgui_cursor];
		}
		else
		{
			bd.MouseCursors[ImGui.MouseCursor.Arrow];
		}
		
		if bd.MouseLastCursor != expected_cursor
		{
			SDL_SetCursor(expected_cursor);
			bd.MouseLastCursor = expected_cursor;
		}
		
		SDL_ShowCursor(xx SDL_TRUE);
	}
}

ImGui_ImplSDL2_CloseGamepads :: ()
{
	bd := ImGui_ImplSDL2_GetBackendData();
	if bd.GamepadMode != .Manual then for bd.Gamepads SDL_GameControllerClose(it);
		
	bd.Gamepads.Size = 0;
}

ImGui_ImplSDL2_UpdateGamepadButton :: (
	bd: *ImGui_ImplSDL2_Data, 
	io: *ImGui.IO, 
	key: ImGui.Key, 
	button_no: SDL_GameControllerButton
)
{
	merged_value := false;
	for bd.Gamepads merged_value |= SDL_GameControllerGetButton(it, button_no) != 0;
	io.AddKeyEvent(io, key, merged_value);
}

Saturate :: (v: float32) -> float32
{
	return ifx v < 0.0 then 
		0.0
	else 
		ifx v > 1.0 then 
			1.0
		else 
			v;
}

ImGui_ImplSDL2_UpdateGamepadAnalog :: (
	bd: *ImGui_ImplSDL2_Data, 
	io: *ImGui.IO, 
	key: ImGui.Key, 
	axis_no: SDL_GameControllerAxis, 
	v0: float32, 
	v1: float32
)
{
	merged_value := 0.0;
	for gamepad: bd.Gamepads
	{
		axis_value := SDL_GameControllerGetAxis(gamepad, axis_no);
		vn := Saturate(cast(float32) (axis_value - v0) / cast(float32) (v1 - v0));
		
		if merged_value < vn then merged_value = vn;
	}
	
	io.AddKeyAnalogEvent(io, key, merged_value > 0.1, merged_value);
}


ImGui_ImplSDL2_UpdateGamepads :: ()
{
	bd := ImGui_ImplSDL2_GetBackendData();
	io := ImGui.GetIO();
	
	if bd.WantUpdateGamepadsList && bd.GamepadMode != .Manual
	{
		ImGui_ImplSDL2_CloseGamepads();
		joystick_count := SDL_NumJoysticks();
		for i: 0..joystick_count - 1
		{
			if !SDL_IsGameController(i) then continue;
			
			gamepad := SDL_GameControllerOpen(i);
			if gamepad == null then continue;
			
			ImGui.vector_push_back(*bd.Gamepads, gamepad);
			if bd.GamepadMode == .AutoFirst then break;
		}
		
		bd.WantUpdateGamepadsList = false;
	}
	
	if (io.ConfigFlags_ & .NavEnableGamepad) == 0 then return;
	io.BackendFlags_ &= ~.HasGamepad;
	if bd.Gamepads.Size == 0 then return;
	io.BackendFlags_ |= .HasGamepad;
	
	thumb_dead_zone: s32 = 8000;
	
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadStart, SDL_CONTROLLER_BUTTON_START);
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadBack, SDL_CONTROLLER_BUTTON_BACK);
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadFaceLeft,
		SDL_CONTROLLER_BUTTON_X); // Xbox X, PS Square
	ImGui_ImplSDL2_UpdateGamepadButton(
		bd, io, .GamepadFaceRight,
		SDL_CONTROLLER_BUTTON_B); // Xbox B, PS Circle
	ImGui_ImplSDL2_UpdateGamepadButton(
		bd, io, .GamepadFaceUp,
		SDL_CONTROLLER_BUTTON_Y); // Xbox Y, PS Triangle
	ImGui_ImplSDL2_UpdateGamepadButton(
		bd, io, .GamepadFaceDown,
		SDL_CONTROLLER_BUTTON_A); // Xbox A, PS Cross
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadDpadLeft,
									   SDL_CONTROLLER_BUTTON_DPAD_LEFT);
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadDpadRight,
									   SDL_CONTROLLER_BUTTON_DPAD_RIGHT);
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadDpadUp,
									   SDL_CONTROLLER_BUTTON_DPAD_UP);
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadDpadDown,
									   SDL_CONTROLLER_BUTTON_DPAD_DOWN);
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadL1,
									   SDL_CONTROLLER_BUTTON_LEFTSHOULDER);
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadR1,
									   SDL_CONTROLLER_BUTTON_RIGHTSHOULDER);
	ImGui_ImplSDL2_UpdateGamepadAnalog(
		bd, io, .GamepadL2, SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0.0, 32767);
	ImGui_ImplSDL2_UpdateGamepadAnalog(bd, io, .GamepadR2,
									   SDL_CONTROLLER_AXIS_TRIGGERRIGHT, 0.0,
									   32767);
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadL3,
									   SDL_CONTROLLER_BUTTON_LEFTSTICK);
	ImGui_ImplSDL2_UpdateGamepadButton(bd, io, .GamepadR3,
									   SDL_CONTROLLER_BUTTON_RIGHTSTICK);
	ImGui_ImplSDL2_UpdateGamepadAnalog(bd, io, .GamepadLStickLeft,
									   SDL_CONTROLLER_AXIS_LEFTX,
									   xx -thumb_dead_zone, -32768);
	ImGui_ImplSDL2_UpdateGamepadAnalog(bd, io, .GamepadLStickRight,
									   SDL_CONTROLLER_AXIS_LEFTX,
									   xx +thumb_dead_zone, +32767);
	ImGui_ImplSDL2_UpdateGamepadAnalog(bd, io, .GamepadLStickUp,
									   SDL_CONTROLLER_AXIS_LEFTY,
									   xx -thumb_dead_zone, -32768);
	ImGui_ImplSDL2_UpdateGamepadAnalog(bd, io, .GamepadLStickDown,
									   SDL_CONTROLLER_AXIS_LEFTY,
									   xx +thumb_dead_zone, +32767);
	ImGui_ImplSDL2_UpdateGamepadAnalog(bd, io, .GamepadRStickLeft,
									   SDL_CONTROLLER_AXIS_RIGHTX,
									   xx -thumb_dead_zone, -32768);
	ImGui_ImplSDL2_UpdateGamepadAnalog(bd, io, .GamepadRStickRight,
									   SDL_CONTROLLER_AXIS_RIGHTX,
									   xx +thumb_dead_zone, +32767);
	ImGui_ImplSDL2_UpdateGamepadAnalog(bd, io, .GamepadRStickUp,
									   SDL_CONTROLLER_AXIS_RIGHTY,
									   xx -thumb_dead_zone, -32768);
	ImGui_ImplSDL2_UpdateGamepadAnalog(bd, io, .GamepadRStickDown,
									   SDL_CONTROLLER_AXIS_RIGHTY,
									   xx +thumb_dead_zone, +32767);
}

ImGui_ImplSDL2_UpdateMonitors :: ()
{
	bd := ImGui_ImplSDL2_GetBackendData();
	platform_io := ImGui.GetPlatformIO();
	
	platform_io.Monitors.Size = 0;
	bd.WantUpdateMonitors = false;
	
	display_count := SDL_GetNumVideoDisplays();
	for i : 0..display_count - 1
	{
		monitor: ImGui.PlatformMonitor;
		r: SDL_Rect;
		SDL_GetDisplayBounds(i, *r);
		monitor.MainPos = ImGui.ImVec2.{cast(float32) r.x, cast(float32) r.y};
		monitor.WorkPos = monitor.MainPos;
		monitor.MainSize = ImGui.ImVec2.{cast(float32) r.w, cast(float32) r.h};
		monitor.WorkSize = monitor.MainSize;
		
		// #if SDL_HAS_USABLE_DISPLAY_BOUNDS
		SDL_GetDisplayUsableBounds(i, *r);
		monitor.WorkPos = ImGui.ImVec2.{cast(float32) r.x, cast(float32) r.y};
		monitor.WorkSize = ImGui.ImVec2.{cast(float32) r.w, cast(float32) r.h};
		// #endif
		// #if SDL_HAS_PER_MONITOR_DPI
		dpi := 0.0;
		if !SDL_GetDisplayDPI(i, *dpi, null, null)
			monitor.DpiScale = dpi / 96.0;
		// #endif
		monitor.PlatformHandle = cast(*void) cast(s64) i;
		ImGui.vector_push_back(*platform_io.Monitors, monitor);
	}
}


