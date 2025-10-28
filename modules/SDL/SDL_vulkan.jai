SDL_HAS_VULKAN :: 1;

SDL_Vulkan_GetInstanceExtensions :: (window: *SDL_Window, pCount: *u32, pNames: **u8) -> SDL_bool #foreign SDL2;

SDL_Vulkan_CreateSurface :: (window: *SDL_Window, instance: VkInstance, surface: *VkSurfaceKHR) -> SDL_bool #foreign SDL2;

SDL_Vulkan_GetDrawableSize :: (window: *SDL_Window, w: *s32, h: *s32) -> SDL_bool #foreign SDL2;
