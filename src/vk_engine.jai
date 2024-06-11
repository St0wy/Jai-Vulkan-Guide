VALIDATION_ENABLED :: BUILD_TYPE != .RELEASE;
REQUIRED_VALIDATION_LAYERS :: (*u8).["VK_LAYER_KHRONOS_validation"];
// FRAME_OVERLAP :: 2;

VulkanEngine :: struct 
{
	window: *SDL_Window;

	window_extent: VkExtent2D;
	instance: VkInstance;
	debug_messenger: VkDebugUtilsMessengerEXT;
	physical_device: VkPhysicalDevice;
	device: VkDevice;
	surface: VkSurfaceKHR;
	graphics_queue: VkQueue;
	present_queue: VkQueue;
	swapchain: VkSwapchainKHR;
	swapchain_images: [..] VkImage;
	swapchain_image_views: [..] VkImageView;
	swapchain_image_format: VkFormat;
	swapchain_extent: VkExtent2D;
	frames: [..] FrameData;
	gpu_allocator: VmaAllocator;
	draw_image: AllocatedImage;
	draw_extent: VkExtent2D;
	global_descriptor_allocator: DescriptorAllocator;
	draw_image_descriptors: VkDescriptorSet;
	draw_image_descriptor_layout: VkDescriptorSetLayout;
	present_mode: VkPresentModeKHR;
	
	// gradient_pipeline: VkPipeline;
	// gradient_pipeline_layout: VkPipelineLayout;
	background_effect: ComputeEffect;
	
	imgui_descriptor_pool: VkDescriptorPool;
	// imgui_context: *ImGui.ImGuiContext;

	frame_number: int;
	is_initialized: bool;
	should_stop_rendering: bool;
	is_minimized: bool;
	resize_requested: bool;
	show_demo_window: bool;
	show_demo_window = true;
	dpi_scale: float32;
	dpi_scale = 1.0;
}

InitVulkanEngine :: (width: s32, height: s32) -> *VulkanEngine 
{
	result_sdl := SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER | SDL_INIT_GAMECONTROLLER);
	if result_sdl != 0
	{
		log_error("Could not load SDL : %\n", to_string(SDL_GetError()));
		return null;
	}
	
	vulkan_engine := New(VulkanEngine);

	sdl_flags: SDL_WindowFlags = SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | 
		SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_VULKAN;
	vulkan_engine.window = SDL_CreateWindow("Hello Vulkan with Jai", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, width, height, sdl_flags);
	if vulkan_engine.window == null 
	{
		log_error("Could not create window: %\n", to_string(SDL_GetError()));
		return null;
	}

	pixel_width, pixel_height: s32;
	SDL_Vulkan_GetDrawableSize(vulkan_engine.window, *pixel_width, *pixel_height);
	vulkan_engine.dpi_scale = cast(float) pixel_width / cast(float) width;
	vulkan_engine.window_extent = .{xx pixel_width, xx pixel_height};

	result := InitVulkan(vulkan_engine);
	if !result 
	{
		log_error("Could not initialize vulkan.\n");
		return null;
	}
	
	vulkan_engine.is_initialized = true;

	return vulkan_engine;
}

DeleteVulkanEngine :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	assert(vulkan_engine != null);

	defer free(vulkan_engine);
	if !vulkan_engine.is_initialized then return;
	
	vkDeviceWaitIdle(device);
	
	ImGui_ImplVulkan_Shutdown();
	ImGui_ImplSDL2_Shutdown();
	ImGui.DestroyContext();
	
	for frames 
	{
		vkDestroyCommandPool(device, it.command_pool, null);
		vkDestroyFence(device, it.render_fence, null);
		vkDestroySemaphore(device, it.render_semaphore, null);
		vkDestroySemaphore(device , it.swapchain_semaphore, null);
	}
	
	vkDestroyDescriptorSetLayout(device, draw_image_descriptor_layout, null);
	DestroyPool(*global_descriptor_allocator, device);
	vkDestroyPipelineLayout(device, background_effect.layout, null);
	vkDestroyPipeline(device, background_effect.pipeline, null);
	
	vkDestroyDescriptorPool(device, imgui_descriptor_pool, null);
	
	DestroySwapchain(vulkan_engine);
	
	vkDestroyImageView(device, draw_image.image_view, null);
	vmaDestroyImage(gpu_allocator, draw_image.image, draw_image.allocation);
	
	vmaDestroyAllocator(gpu_allocator);
	
	vkDestroyDevice(device, null);

	#if VALIDATION_ENABLED
	{
		DestroyDebugUtilsMessengerEXT(instance, debug_messenger, null);
	}

	vkDestroySurfaceKHR(instance, surface, null);
	vkDestroyInstance(instance, null);
		
	array_free(swapchain_images);
	array_free(swapchain_image_views);
	array_free(frames);

	SDL_DestroyWindow(window);
	SDL_Quit();
}

RunVulkanEngine :: (vulkan_engine: *VulkanEngine) 
{
	last_time: float64;
	while !vulkan_engine.should_stop_rendering 
	{
		current_time := seconds_since_init();
		delta_time := current_time - last_time;
		last_time = current_time;
		
		event: SDL_Event;
		while SDL_PollEvent(*event)
		{
			ImGui_ImplSDL2_ProcessEvent(*event);
			if event.type ==
			{
				case SDL_QUIT;
					vulkan_engine.should_stop_rendering = true;
				case SDL_KEYUP;
					if event.key.keysym.sym == SDLK_ESCAPE 
					{
						vulkan_engine.should_stop_rendering = true;
					}
				case SDL_WINDOWEVENT;
					if event.window.event == 
					{
						case SDL_WINDOWEVENT_MINIMIZED;
							vulkan_engine.is_minimized = true;
						case SDL_WINDOWEVENT_RESTORED;
							vulkan_engine.is_minimized = false;
						case SDL_WINDOWEVENT_RESIZED;
							vulkan_engine.resize_requested = true;	
					}
			}
		}
		
		if vulkan_engine.resize_requested then ResizeSwapchain(vulkan_engine);
		
		if vulkan_engine.is_minimized 
		{
			sleep_milliseconds(100);
		}
		else
		{
			Draw(vulkan_engine, delta_time);
		}
		
		reset_temporary_storage();
	}
}

Draw :: (vulkan_engine: *VulkanEngine, delta_time: float64)
{
	using vulkan_engine;
	
	ONE_SECOND_IN_NS :: 1000000000;
	
	current_frame := GetCurrentFrame(vulkan_engine);
	
	result := vkWaitForFences(device, 1, *current_frame.render_fence, VK_TRUE, ONE_SECOND_IN_NS);
	assert(result == .SUCCESS, "Could not wait for fences");
	
	result = vkResetFences(device, 1, *current_frame.render_fence);
	assert(result == .SUCCESS, "Could not reset fences");
	
	// TODO Delete frame data here
	
	swapchain_image_index: u32;
	result = vkAcquireNextImageKHR(
		device, 
		swapchain, 
		ONE_SECOND_IN_NS, 
		current_frame.swapchain_semaphore, 
		null, 
		*swapchain_image_index
	);
	
	if result == .ERROR_OUT_OF_DATE_KHR || result == .VK_SUBOPTIMAL_KHR then vulkan_engine.resize_requested = true;
	else assert(result == .SUCCESS, "Could not acquire next image");
	
	cmd := current_frame.main_command_buffer;
	result = vkResetCommandBuffer(cmd, 0);
	assert(result == .SUCCESS, "Could not reset command buffer");
	
	cmd_begin_info := CommandBufferBeginInfo(.ONE_TIME_SUBMIT_BIT);
	
	draw_extent.width = draw_image.image_extent.width;
	draw_extent.height = draw_image.image_extent.height;
	
	result = vkResetCommandPool(device, current_frame.command_pool, 0);
	assert(result == .SUCCESS, "Could not reset command pool");
	
	result = vkBeginCommandBuffer(cmd, *cmd_begin_info);
	assert(result == .SUCCESS, "Could not begin command buffer");
	
	TransitionImage(cmd, draw_image.image, .UNDEFINED, .GENERAL);
	
	vkCmdBindPipeline(cmd, .COMPUTE, background_effect.pipeline);
	vkCmdBindDescriptorSets(
		cmd, .COMPUTE, background_effect.layout, 0, 1, *draw_image_descriptors, 0, null);
	
	vkCmdPushConstants(
		cmd, 
		background_effect.layout, 
		.COMPUTE_BIT, 
		0, 
		size_of(ComputePushConstants), 
		*background_effect.data
	);
		
	vkCmdDispatch(cmd, xx ceil(draw_extent.width / 16.0), xx ceil(draw_extent.height / 16.0), 1);
	
	// clear_value: VkClearColorValue;
	// flash := pow(abs(sin(seconds_since_init())), 2.2);
	// clear_value._float32 = float32.[0.0, 0.0, xx flash, 1.0];
	
	// clear_range := ImageSubresourceRange(.COLOR_BIT);
	// vkCmdClearColorImage(cmd, draw_image.image, .GENERAL, *clear_value, 1, *clear_range);
	
	TransitionImage(cmd, draw_image.image, .GENERAL, .TRANSFER_SRC_OPTIMAL);
	
	swapchain_image := swapchain_images[swapchain_image_index];
	TransitionImage(cmd, swapchain_image, .UNDEFINED, .TRANSFER_DST_OPTIMAL);
	
	CopyImageToImage(cmd, draw_image.image, swapchain_image, draw_extent, swapchain_extent);
	
	TransitionImage(cmd, swapchain_image, .TRANSFER_DST_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL);
	
	// Draw ImGui
	ImGui_ImplVulkan_NewFrame();
	ImGui_ImplSDL2_NewFrame();
	ImGui.NewFrame();
	
	if ImGui.Begin("Background")
	{
		ImGui.InputFloat4("data1",cast(*[4] float) *background_effect.data.data1);
		ImGui.InputFloat4("data2",cast(*[4] float) *background_effect.data.data2);
		ImGui.InputFloat4("data3",cast(*[4] float) *background_effect.data.data3);
		ImGui.InputFloat4("data4",cast(*[4] float) *background_effect.data.data4);
	}
	
	ImGui.End();
    
	ImGui.Render();
    
	draw_data := ImGui.GetDrawData();
	
	attachment_info: VkRenderingAttachmentInfo;
    attachment_info.imageView = swapchain_image_views[swapchain_image_index];
    attachment_info.imageLayout = .COLOR_ATTACHMENT_OPTIMAL;
    attachment_info.loadOp = .LOAD;
    attachment_info.storeOp = .STORE;

    rendering_info: VkRenderingInfo;
    rendering_info.renderArea.extent = swapchain_extent;
    rendering_info.layerCount = 1;
    rendering_info.colorAttachmentCount = 1;
    rendering_info.pColorAttachments = *attachment_info;

    vkCmdBeginRendering(cmd, *rendering_info);
    
	ImGui_ImplVulkan_RenderDrawData(draw_data, cmd);
	
	vkCmdEndRendering(cmd);
	
	TransitionImage(cmd, swapchain_image, .COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR);
	
	result = vkEndCommandBuffer(cmd);
	assert(result == .SUCCESS, "Error while ending command buffer");
	
	cmd_info := CommandBufferSubmitInfo(cmd);
	wait_info := SemaphoreSubmitInfo(
		VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT_KHR, 
		current_frame.swapchain_semaphore
	);
	signal_info := SemaphoreSubmitInfo(
		VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT, 
		current_frame.render_semaphore
	);
	
	submit := SubmitInfo(*cmd_info, *signal_info, *wait_info);
	result = vkQueueSubmit2(graphics_queue, 1, *submit, current_frame.render_fence);
	
	present_info: VkPresentInfoKHR;
	present_info.pSwapchains = *swapchain;
	present_info.swapchainCount = 1;
	present_info.pWaitSemaphores = *current_frame.render_semaphore;
	present_info.waitSemaphoreCount = 1;
	present_info.pImageIndices = *swapchain_image_index;
	
	result = vkQueuePresentKHR(present_queue, *present_info);
	
	if result == .ERROR_OUT_OF_DATE_KHR || result == .VK_SUBOPTIMAL_KHR then resize_requested = true;
	else assert(result == .SUCCESS, "Error while presenting queue");
	
	frame_number += 1;
}

#scope_file

AllocImGui :: (sz: u64, user_data: *void) -> *void #c_call
{
	new_context: Context;
	push_context new_context
	{
		return alloc(xx sz);
	}
}

FreeImGui :: (ptr: *void, user_data: *void) #c_call
{
	new_context: Context;
	push_context new_context
	{
		free(ptr);
	}
}

InitImGui :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	ImGui.SetAllocatorFunctions(AllocImGui, FreeImGui);
	ImGui.CreateContext();
	
	io := ImGui.GetIO();
    io.ConfigFlags_ |= .NavEnableKeyboard;
    io.ConfigFlags_ |= .NavEnableGamepad;
    io.ConfigFlags_ |= .DockingEnable;
    
    ImGui.StyleColorsDark();
	
	result := ImGui_ImplSDL2_InitForVulkan(vulkan_engine.window);
	assert(result, "Could not init ImGui SDL2 backend for Vulkan");
	
	indices := FindQueueFamilies(physical_device, surface);
	assert(indices.has_graphics_family);
	
	color_format := VkFormat.[];
	
	pipeline_rendering_info: VkPipelineRenderingCreateInfoKHR;
	pipeline_rendering_info.colorAttachmentCount = 1;
	pipeline_rendering_info.pColorAttachmentFormats = *swapchain_image_format;
	
	init_info: ImGui_ImplVulkan_InitInfo;
    init_info.Instance = instance;
    init_info.PhysicalDevice = physical_device;
    init_info.Device = device;
    init_info.QueueFamily = indices.graphics_family;
    init_info.Queue = graphics_queue;
    init_info.PipelineCache = VK_NULL_HANDLE;
    init_info.DescriptorPool = imgui_descriptor_pool;
    init_info.RenderPass = null;
    init_info.UseDynamicRendering = true;
    init_info.PipelineRenderingCreateInfo = pipeline_rendering_info;
    init_info.Subpass = 0;
    init_info.MinImageCount = xx swapchain_images.count;
    init_info.ImageCount = xx swapchain_images.count;
    init_info.MSAASamples = ._1_BIT;
    init_info.Allocator = null;
    init_info.CheckVkResultFn = CheckImGuiVkResult;
	result = ImGui_ImplVulkan_Init(*init_info);
	assert(result, "Could not init ImGui Vulkan backend");

	imgui_style := ImGui.GetStyle();
	imgui_style.ScaleAllSizes(imgui_style, dpi_scale);
	// io.FontGlobalScale = dpi_scale;
	// io.DisplayFrameBufferScale  = 1;
	
	FONT_SIZE :: 13.0;
	scaled_font_size := cast(float32) cast(s32) (FONT_SIZE * dpi_scale);
	
	font_cfg: ImGui.ImFontConfig;
	ImGui.ImFontConfig.Constructor(*font_cfg);
    font_cfg.FontDataOwnedByAtlas = false;
	font_cfg.OversampleH = 3;
	font_cfg.OversampleV = 3;
	font_cfg.SizePixels = scaled_font_size;
}

CheckImGuiVkResult :: (err: VkResult)
{
	assert(err == .SUCCESS, tprint("An error occured inside imgui : %\n", err));
}

VulkanDebugCallback :: (
	messageSeverity: VkDebugUtilsMessageSeverityFlagBitsEXT, 
	messageType: VkDebugUtilsMessageTypeFlagsEXT,
	pCallbackData: *VkDebugUtilsMessengerCallbackDataEXT, 
	pUserData: *void
) -> VkBool32 #c_call 
{
	new_context: Context;
	push_context new_context 
	{
		new_context.logger = Logger;
		
		message := to_string(pCallbackData.pMessage);
		if messageSeverity ==
		{
			case .VERBOSE_BIT_EXT;
				log("VULKAN_VALIDATION(VERBOSE): %\n", message, flags = .VERY_VERBOSE_ONLY);
			case .INFO_BIT_EXT;
				log("VULKAN_VALIDATION(INFO): %\n", message, flags = .VERBOSE_ONLY);
			case .WARNING_BIT_EXT;
				log("VULKAN_VALIDATION(WARNING): %\n", message, flags = .WARNING);
			case .ERROR_BIT_EXT;
				log_error("VULKAN_VALIDATION(ERROR): %\n", message);
				assert(false);
			case;
				log("VULKAN_VALIDATION(UNKOWN): %\n", message);
			
		}
	}

	return VK_FALSE;
}

InitVulkan :: (vulkan_engine: *VulkanEngine) -> bool
{
	log("Init Vulkan\n");

	result := CreateInstance(vulkan_engine);
	if !result 
	{
		log_error("Failed to create instance.\n");
		return false;
	}

	#if BUILD_TYPE != .RELEASE 
	{
		SetupDebugMessenger(vulkan_engine);
	}
	
	CreateSurface(vulkan_engine);
	PickPhysicalDevice(vulkan_engine);
	CreateLogicalDevice(vulkan_engine);
	
	allocator_info: VmaAllocatorCreateInfo;
	allocator_info.physicalDevice = vulkan_engine.physical_device;
	allocator_info.device = vulkan_engine.device;
	allocator_info.instance = vulkan_engine.instance;
	allocator_info.flags = .VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT;
	allocator_info.vulkanApiVersion = VK_API_VERSION_1_3;
	vmaCreateAllocator(*allocator_info, *vulkan_engine.gpu_allocator);
	
	CreateSwapchain(vulkan_engine);
	CreateDrawImage(vulkan_engine);
	CreateSwapchainImageViews(vulkan_engine);
	InitCommands(vulkan_engine);
	InitSyncStructure(vulkan_engine);
	InitDescriptors(vulkan_engine);
	InitPipelines(vulkan_engine);
	
	{
		pool_sizes := VkDescriptorPoolSize.[.{.COMBINED_IMAGE_SAMPLER, 1}];
		pool_info: VkDescriptorPoolCreateInfo;
		pool_info.flags = .FREE_DESCRIPTOR_SET_BIT;
        pool_info.maxSets = 1;
        pool_info.poolSizeCount = pool_sizes.count;
        pool_info.pPoolSizes = pool_sizes.data;
        err := vkCreateDescriptorPool(vulkan_engine.device, *pool_info, null, *vulkan_engine.imgui_descriptor_pool);
        assert(err == .SUCCESS, "Could not create descriptor pool");
	}
	
	InitImGui(vulkan_engine);

	return true;
}

CreateInstance :: (vulkan_engine: *VulkanEngine) -> bool 
{
	assert(vulkan_engine != null);

	#if VALIDATION_ENABLED 
	{
		if !SupportsValidationLayers() 
		{
			log_error("This GPU doesn't support validation layers.\n");
			return false;
		}
	}

	result := VkResult.ERROR_INITIALIZATION_FAILED;

	app_info: VkApplicationInfo;
	app_info.pApplicationName = "Vulkan example";
	app_info.applicationVersion = #run VK_MAKE_API_VERSION(0, 1, 0, 0);
	app_info.pEngineName = "No Engine";
	app_info.engineVersion = #run VK_MAKE_API_VERSION(0, 1, 0, 0);
	app_info.apiVersion = VK_API_VERSION_1_3;

	create_info: VkInstanceCreateInfo;
	create_info.pApplicationInfo = *app_info;


	required_extensions, went_well := GetRequiredExtension(vulkan_engine);
	if !went_well then return false;

	create_info.enabledExtensionCount = xx required_extensions.count;
	create_info.ppEnabledExtensionNames = required_extensions.data;

	#if VALIDATION_ENABLED
	{
		create_info.enabledLayerCount = REQUIRED_VALIDATION_LAYERS.count;
		create_info.ppEnabledLayerNames = REQUIRED_VALIDATION_LAYERS.data;

		debug_create_info := CreateDebugMessengerCreateInfo();
		create_info.pNext = cast(*VkDebugUtilsMessengerCreateInfoEXT) *debug_create_info;
	}
	else
	{
		create_info.enabledLayerCount = 0;
	}

	result = vkCreateInstance(*create_info, null, *vulkan_engine.instance);

	return result == .SUCCESS;
}

SupportsValidationLayers :: () -> bool 
{
	layer_count: u32;
	vkEnumerateInstanceLayerProperties(*layer_count, null);

	available_layers: [] VkLayerProperties;
	available_layers.data = temporary_alloc(layer_count * size_of(VkLayerProperties));
	available_layers.count = layer_count;

	vkEnumerateInstanceLayerProperties(*layer_count, available_layers.data);

	for layer_name: REQUIRED_VALIDATION_LAYERS
	{
		layer_found := false;

		for layer_properties: available_layers 
		{
			layer_property_name := cast(string) layer_properties.layerName;
			layer_name_string := to_string(layer_name);
			layer_property_name.count = layer_name_string.count;

			if compare(layer_name_string, layer_property_name) == 0
			{
				layer_found = true;
				break;
			}
		}

		if !layer_found then return false;
	}

	return true;
}

// Will return the required extensions, allocated on the temp allocator
GetRequiredExtension :: (vulkan_engine: *VulkanEngine) -> [..] *u8, bool
{
	required_extensions: [..] *u8;
	required_extensions.allocator = temp;

	extensions_count: u32;
	could_get_instance_extensions_count := 
		SDL_Vulkan_GetInstanceExtensions(vulkan_engine.window, *extensions_count, null);
	if !could_get_instance_extensions_count 
	{
		log_error("Could not get instance extensions count from SDL.\n");
		return required_extensions, false;
	}

	
	array_reserve(*required_extensions, xx extensions_count);
	required_extensions.count = xx extensions_count;

	could_get_instance_extensions := 
		SDL_Vulkan_GetInstanceExtensions(vulkan_engine.window, *extensions_count, required_extensions.data);
	if !could_get_instance_extensions 
	{
		log_error("Could not get instance extensions from SDL.\n");
		return required_extensions, false;
	}

	#if OS == .MACOS 
	{
		array_add(*required_extensions, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME.data);
		create_info.flags |= .VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
	}

	#if BUILD_TYPE != .RELEASE
	{
		array_add(*required_extensions, VK_EXT_DEBUG_UTILS_EXTENSION_NAME.data);
	}

	return required_extensions, true;
}

CreateDebugUtilsMessengerEXT :: (
	instance: VkInstance,
	pCreateInfo: *VkDebugUtilsMessengerCreateInfoEXT,
	pAllocator: *VkAllocationCallbacks,
	pDebugMessenger: *VkDebugUtilsMessengerEXT
) -> VkResult
{
	func := cast(PFN_vkCreateDebugUtilsMessengerEXT) vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");
	if func != null
	{
		return func(instance, pCreateInfo, pAllocator, pDebugMessenger);
	}
	else
	{
		return .ERROR_EXTENSION_NOT_PRESENT;
	}
}

DestroyDebugUtilsMessengerEXT :: (
	instance: VkInstance,
	debugMessenger: VkDebugUtilsMessengerEXT,
	pAllocator: *VkAllocationCallbacks
)
{
	func := cast(PFN_vkDestroyDebugUtilsMessengerEXT) vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT");
	if func != null then func(instance, debugMessenger, pAllocator);
}

CreateDebugMessengerCreateInfo :: () -> VkDebugUtilsMessengerCreateInfoEXT
{
	create_info: VkDebugUtilsMessengerCreateInfoEXT;
	create_info.messageSeverity = .WARNING_BIT_EXT | .ERROR_BIT_EXT;
	create_info.messageType = .GENERAL_BIT_EXT | .VALIDATION_BIT_EXT | .PERFORMANCE_BIT_EXT;
	create_info.pfnUserCallback = VulkanDebugCallback;

	return create_info;
}

SetupDebugMessenger :: (vulkan_engine: *VulkanEngine) 
{
	create_info := CreateDebugMessengerCreateInfo();

	result := CreateDebugUtilsMessengerEXT(
		vulkan_engine.instance, 
		*create_info, 
		null, 
		*vulkan_engine.debug_messenger
	);
	
	assert(result == .SUCCESS, "Could not setup debug messenger.");
}

CreateSurface :: (vulkan_engine: *VulkanEngine)
{
	could_create_surface := SDL_Vulkan_CreateSurface(
		vulkan_engine.window, 
		vulkan_engine.instance, 
		*vulkan_engine.surface
	);
	assert(could_create_surface == .SDL_TRUE, "Failed to create Vulkan surface.");
}

ScoredDevice :: struct
{
	score: int;
	device: VkPhysicalDevice;
}

PickPhysicalDevice :: (vulkan_engine: *VulkanEngine)
{
	device_count: u32;
	vkEnumeratePhysicalDevices(vulkan_engine.instance, *device_count, null);
	if device_count == 0 
	{
		log_error("Could not find a GPU with Vulkan support.\n");
	}

	devices: [] VkPhysicalDevice;
	devices.count = device_count;
	devices.data = temporary_alloc(devices.count * size_of(VkPhysicalDevice));
	vkEnumeratePhysicalDevices(vulkan_engine.instance, *device_count, devices.data);

	scored_devices: [..] ScoredDevice;
	scored_devices.allocator = temp;

	for device: devices 
	{
		score := RateDeviceSuitability(device, vulkan_engine.surface);
		if score != 0
		{
			array_add(*scored_devices, ScoredDevice.{score, device});
		}
	}
	
	assert(scored_devices.count != 0, "Failed to find a suitable GPU.");
	
	highest_scored_device: ScoredDevice;
	for scored_device: scored_devices
	{
		if scored_device.score > highest_scored_device.score
		{
			highest_scored_device = scored_device;
		}
	}
	
	vulkan_engine.physical_device = highest_scored_device.device;
}

// A score of 0 indicates that the device is not suitable
RateDeviceSuitability :: (device: VkPhysicalDevice, surface: VkSurfaceKHR) -> int 
{
	properties: VkPhysicalDeviceProperties2;
	vkGetPhysicalDeviceProperties2(device, *properties);
	
	indices := FindQueueFamilies(device, surface);
	if !IsQueueFamilyComplete(indices) then return 0;
	if !CheckPhysicalDeviceExtensions(device) then return 0;
	if !CheckVulkanFeatures(device) then return 0;
	
	swapchain_support := QuerySwapchainSupport(device, surface);
	if swapchain_support.formats.count == 0 || swapchain_support.present_modes.count == 0
		return 0;

	if properties.properties.apiVersion < VK_API_VERSION_1_3 then return 0;
	
	score := 100;
	if properties.properties.deviceType == .DISCRETE_GPU then score += 1000;
	score += properties.properties.limits.maxImageDimension2D;
	
	return score;
}

QueueFamilyIndices :: struct
{
	graphics_family: u32;
	present_family: u32;
	has_graphics_family: bool;
	has_present_family: bool;
}

IsQueueFamilyComplete :: (indices: QueueFamilyIndices) -> bool 
{
	return indices.has_graphics_family && indices.has_present_family;
}

FindQueueFamilies :: (device: VkPhysicalDevice, surface: VkSurfaceKHR) -> QueueFamilyIndices
{
	indices: QueueFamilyIndices;

	queue_family_count: u32;
	vkGetPhysicalDeviceQueueFamilyProperties(device, *queue_family_count, null);

	queue_families: [] VkQueueFamilyProperties;
	queue_families.count = queue_family_count;
	queue_families.data = temporary_alloc(queue_families.count * size_of(VkQueueFamilyProperties));
	vkGetPhysicalDeviceQueueFamilyProperties(device, *queue_family_count, queue_families.data);

	for i: 0..queue_families.count - 1
	{
		if queue_families[i].queueFlags & .GRAPHICS_BIT
		{
			indices.graphics_family = xx i;
			indices.has_graphics_family = true;
		}
		
		present_support: VkBool32;
		vkGetPhysicalDeviceSurfaceSupportKHR(device, xx i, surface, *present_support);
		if present_support == VK_TRUE
		{
			indices.present_family = xx i;
			indices.has_present_family = true;
		}

		if IsQueueFamilyComplete(indices) then break;
	}

	return indices;
}

CheckPhysicalDeviceExtensions :: (device: VkPhysicalDevice) -> bool
{
	extensions_count: u32;
	result := vkEnumerateDeviceExtensionProperties(device, null, *extensions_count, null);
	if result != .SUCCESS
	{
		log_error("Failed to enumerate device extensions for a physical device\n");
		return false;
	}

	extensions: [] VkExtensionProperties;
	extensions.count = extensions_count;
	extensions.data = temporary_alloc(extensions_count * size_of(VkExtensionProperties));
	result = vkEnumerateDeviceExtensionProperties(device, null, *extensions_count, extensions.data);
	if result != .SUCCESS
	{
		log_error("Failed to enumerate device extensions for a physical device\n");
		return false;
	}

	DEVICE_REQUIRED_EXTENSION_NAMES :: string.[VK_KHR_SWAPCHAIN_EXTENSION_NAME];

	for required_ext_name: DEVICE_REQUIRED_EXTENSION_NAMES
	{
		found_in_available := false;
		for available_extension: extensions
		{
			available_ext_name := cast(string) available_extension.extensionName;
			available_ext_name.count = strlen(*available_extension.extensionName[0]);
			if required_ext_name == available_ext_name then 
			{
				found_in_available = true;
				break;
			}
		}
		
		if !found_in_available then return false;
	}

	return true;
}

CheckVulkanFeatures :: (device: VkPhysicalDevice) -> bool 
{
	vulkan_12_features: VkPhysicalDeviceVulkan12Features;
	features: VkPhysicalDeviceFeatures2;
	features.pNext = *vulkan_12_features;
	vkGetPhysicalDeviceFeatures2(device, *features);

	if !vulkan_12_features.descriptorIndexing || !vulkan_12_features.bufferDeviceAddress
		return false;

	vulkan_13_features: VkPhysicalDeviceVulkan13Features;
	features.pNext = *vulkan_13_features;
	vkGetPhysicalDeviceFeatures2(device, *features);

	if !vulkan_13_features.dynamicRendering || !vulkan_13_features.synchronization2
		 return false;

	return true;
}

SwapchainSupportDetails :: struct
{
	capabilities: VkSurfaceCapabilitiesKHR;
	formats: [] VkSurfaceFormatKHR;
	present_modes: [] VkPresentModeKHR;
}

QuerySwapchainSupport :: (
	device: VkPhysicalDevice, 
	surface: VkSurfaceKHR
) -> SwapchainSupportDetails
{
	details: SwapchainSupportDetails;
	
	vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, *details.capabilities);
	
	format_count: u32;
	vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, *format_count, null);
	
	if format_count > 0
	{
		details.formats.count = format_count;
		details.formats.data = temporary_alloc(format_count * size_of(VkSurfaceFormatKHR));
		vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, *format_count, details.formats.data);
	}
	
	present_mode_count: u32;
	vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, *present_mode_count, null);
	
	if present_mode_count > 0
	{
		details.present_modes.count = present_mode_count;
		details.present_modes.data = 
			temporary_alloc(present_mode_count * size_of(VkPresentModeKHR));
		vkGetPhysicalDeviceSurfacePresentModesKHR(
			device, 
			surface, 
			*present_mode_count, 
			details.present_modes.data
		);
	}
	
	return details;
}

CreateLogicalDevice :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	indices := FindQueueFamilies(physical_device, surface);
	
	indices_array := u32.[indices.graphics_family, indices.present_family];
	unique_indices: [..] u32;
	unique_indices.allocator = temp;
	for indices_array array_add_if_unique(*unique_indices, it);
	
	queue_priority := 1.0;
	queue_infos: [] VkDeviceQueueCreateInfo;
	queue_infos.data = temporary_alloc(unique_indices.count * size_of(VkDeviceQueueCreateInfo));
	queue_infos.count = unique_indices.count;
	
	for unique_indices 
	{
		queue_infos[it_index].sType = .DEVICE_QUEUE_CREATE_INFO;
		queue_infos[it_index].queueFamilyIndex = it;
		queue_infos[it_index].queueCount = 1;
		queue_infos[it_index].pQueuePriorities = *queue_priority;
	}
	
	device_features: VkPhysicalDeviceFeatures;
	
	dynamic_rendering := VkPhysicalDeviceDynamicRenderingFeatures.{dynamicRendering = VK_TRUE};
	sync2 := VkPhysicalDeviceSynchronization2Features.{
		synchronization2 = VK_TRUE, 
		pNext = *dynamic_rendering
	};
	buffer_device_address := VkPhysicalDeviceBufferDeviceAddressFeatures.{
		bufferDeviceAddress = VK_TRUE,
		pNext = *sync2,
	};
	
	extensions :: (*u8).[VK_KHR_SWAPCHAIN_EXTENSION_NAME];
	
	create_info: VkDeviceCreateInfo;
	create_info.pQueueCreateInfos = queue_infos.data;
	create_info.queueCreateInfoCount = xx queue_infos.count;
	create_info.pEnabledFeatures = *device_features;
	create_info.pNext = *buffer_device_address;
	create_info.enabledExtensionCount = extensions.count;
	create_info.ppEnabledExtensionNames = extensions.data;
	
	#if VALIDATION_ENABLED 
	{
		create_info.enabledLayerCount = REQUIRED_VALIDATION_LAYERS.count;
		create_info.ppEnabledLayerNames = REQUIRED_VALIDATION_LAYERS.data;
	}
	
	result := vkCreateDevice(physical_device, *create_info, null, *device);
	assert(result == .SUCCESS, "Failed to create logical device!");
	
	vkGetDeviceQueue(device, indices.graphics_family, 0, *graphics_queue);
	vkGetDeviceQueue(device, indices.present_family, 0, *present_queue);
}

ChooseSwapchainSurfaceFormat :: (available_formats: [] VkSurfaceFormatKHR) -> VkSurfaceFormatKHR
{
	for available_formats
	{
		if it.format == .B8G8R8A8_SRGB && it.colorSpace == .COLOR_SPACE_SRGB_NONLINEAR_KHR
			return it;
	}
	
	return available_formats[0];
}

ChoseSwapchainPresentMode :: (available_present_modes: [] VkPresentModeKHR) -> VkPresentModeKHR
{
	for available_present_modes if it == .MAILBOX_KHR then return it;

	return .FIFO_KHR;
}

ChoseSwapchainExtent :: (capabilities: VkSurfaceCapabilitiesKHR, window: *SDL_Window) -> VkExtent2D
{
	if capabilities.currentExtent.width != U32_MAX then return capabilities.currentExtent;
	
	width, height: s32;
	SDL_GetWindowSize(window, *width, *height);
	
	extent := VkExtent2D.{width = xx width, height = xx height};
	
	extent.width = clamp(
		extent.width, 
		capabilities.minImageExtent.width, 
		capabilities.maxImageExtent.width
	);
	
	extent.height = clamp(
		extent.height, 
		capabilities.minImageExtent.height, 
		capabilities.maxImageExtent.height
	);
	
	return extent;
}

CreateSwapchain :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	swapchain_support := QuerySwapchainSupport(physical_device, surface);
	surface_format := ChooseSwapchainSurfaceFormat(swapchain_support.formats);
	present_mode = ChoseSwapchainPresentMode(swapchain_support.present_modes);
	extent := ChoseSwapchainExtent(swapchain_support.capabilities, window);
	
	image_count := swapchain_support.capabilities.minImageCount + 1;
	max_image_count := swapchain_support.capabilities.maxImageCount;
	if max_image_count > 0 && image_count > max_image_count then image_count = max_image_count;
	
	create_info: VkSwapchainCreateInfoKHR;
	create_info.surface = surface;
	create_info.minImageCount = image_count;
	create_info.imageFormat = surface_format.format;
	create_info.imageColorSpace = surface_format.colorSpace;
	create_info.imageExtent = extent;
	create_info.imageArrayLayers = 1;
	create_info.imageUsage = .COLOR_ATTACHMENT_BIT | .TRANSFER_DST_BIT;
	
	indices := FindQueueFamilies(physical_device, surface);
	queue_family_indices := u32.[indices.graphics_family, indices.present_family];
	
	if indices.graphics_family != indices.present_family
	{
		create_info.imageSharingMode = .CONCURRENT;
		create_info.queueFamilyIndexCount = xx queue_family_indices.count;
		create_info.pQueueFamilyIndices = queue_family_indices.data;
	}
	else
	{
		create_info.imageSharingMode = .EXCLUSIVE;
	}
	
	create_info.preTransform = swapchain_support.capabilities.currentTransform;
	create_info.compositeAlpha = .OPAQUE_BIT_KHR;
	create_info.presentMode = present_mode;
	create_info.clipped = VK_TRUE;
	create_info.oldSwapchain = null;
	
	result := vkCreateSwapchainKHR(device, *create_info, null, *swapchain);
	assert(result == .SUCCESS, "Failed to create swapchain");

	vkGetSwapchainImagesKHR(device, swapchain, *image_count, null);
	array_resize(*swapchain_images, image_count);
	vkGetSwapchainImagesKHR(device, swapchain, *image_count, swapchain_images.data);
	swapchain_image_format = surface_format.format;
	swapchain_extent = extent;
	
	array_resize(*frames, image_count);
}

CreateSwapchainImageViews :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	array_resize(*swapchain_image_views, swapchain_images.count);
	
	for swapchain_images
	{
		create_info: VkImageViewCreateInfo;
		create_info.image = it;
		create_info.viewType = ._2D;
		create_info.format = swapchain_image_format;
		create_info.components.r = .IDENTITY;
		create_info.components.g = .IDENTITY;
		create_info.components.b = .IDENTITY;
		create_info.components.a = .IDENTITY;
		create_info.subresourceRange.aspectMask = .COLOR_BIT;
		create_info.subresourceRange.baseMipLevel = 0;
		create_info.subresourceRange.levelCount = 1;
		create_info.subresourceRange.baseArrayLayer = 0;
		create_info.subresourceRange.layerCount = 1;
		
		result := vkCreateImageView(device, *create_info, null, *swapchain_image_views[it_index]);
	}
}

DestroySwapchain :: (vulkan_engine: *VulkanEngine)
{
	vkDestroySwapchainKHR(vulkan_engine.device, vulkan_engine.swapchain, null);
	for vulkan_engine.swapchain_image_views vkDestroyImageView(vulkan_engine.device, it, null);
}

FrameData :: struct
{
	command_pool: VkCommandPool;
	main_command_buffer: VkCommandBuffer;
	swapchain_semaphore: VkSemaphore;
	render_semaphore: VkSemaphore;
	render_fence: VkFence;
}

GetCurrentFrame :: (vulkan_engine: *VulkanEngine) -> *FrameData
{
	return *vulkan_engine.frames[vulkan_engine.frame_number % vulkan_engine.frames.count];
}

InitCommands :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	indices := FindQueueFamilies(physical_device, surface);
	
	command_pool_info := CommandPoolCreateInfo(indices.graphics_family, .RESET_COMMAND_BUFFER_BIT);
	
	for frames
	{
		result := vkCreateCommandPool(device, *command_pool_info, null, *it.command_pool);
		assert(result == .SUCCESS, "Could not create command pool.");
	
		cmd_alloc_info := CommandBufferAllocateInfo(it.command_pool, 1);
		
		result = vkAllocateCommandBuffers(device, *cmd_alloc_info, *it.main_command_buffer);
		assert(result == .SUCCESS, "Could not allocate command buffer.");
	}
}

InitSyncStructure :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	frence_create_info := FenceCreateInfo(.SIGNALED_BIT);
	semaphore_create_info := SemaphoreCreateInfo();
	
	for frames
	{
		result := vkCreateFence(device, *frence_create_info, null, *it.render_fence);
		assert(result == .SUCCESS, "Could not create fence.");

		result = vkCreateSemaphore(device, *semaphore_create_info, null, *it.swapchain_semaphore);
		assert(result == .SUCCESS, "Could not create semaphore.");
		
		result = vkCreateSemaphore(device, *semaphore_create_info, null, *it.render_semaphore);
		assert(result == .SUCCESS, "Could not create semaphore.");
	}
}

AllocatedImage :: struct
{
	image: VkImage;
	image_view: VkImageView;
	allocation: VmaAllocation;
	image_extent: VkExtent3D;
	image_format: VkFormat;
}

CopyImageToImage :: (
	cmd: VkCommandBuffer, 
	source: VkImage, 
	destination: VkImage, 
	src_size: VkExtent2D, 
	dst_size: VkExtent2D
)
{
	blit_region: VkImageBlit2;
	blit_region.srcOffsets[1].x = xx src_size.width;
	blit_region.srcOffsets[1].y = xx src_size.height;
	blit_region.srcOffsets[1].z = 1;

	blit_region.dstOffsets[1].x = xx dst_size.width;
	blit_region.dstOffsets[1].y = xx dst_size.height;
	blit_region.dstOffsets[1].z = 1;

	blit_region.srcSubresource.aspectMask = .COLOR_BIT;
	blit_region.srcSubresource.baseArrayLayer = 0;
	blit_region.srcSubresource.layerCount = 1;
	blit_region.srcSubresource.mipLevel = 0;

	blit_region.dstSubresource.aspectMask = .COLOR_BIT;
	blit_region.dstSubresource.baseArrayLayer = 0;
	blit_region.dstSubresource.layerCount = 1;
	blit_region.dstSubresource.mipLevel = 0;

	blit_info: VkBlitImageInfo2;
	blit_info.dstImage = destination;
	blit_info.dstImageLayout = .TRANSFER_DST_OPTIMAL;
	blit_info.srcImage = source;
	blit_info.srcImageLayout = .TRANSFER_SRC_OPTIMAL;
	blit_info.filter = .LINEAR;
	blit_info.regionCount = 1;
	blit_info.pRegions = *blit_region;

	vkCmdBlitImage2(cmd, *blit_info);
}

InitDescriptors :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	sizes := PoolSizeRatio.[.{.STORAGE_IMAGE, 1}];
	global_descriptor_allocator = CreateDescriptorAllocator(device, 10, sizes);
	
	{
		builder: DescriptorLayoutBuilder;
		AddBindingToBuilder(*builder, 0, .STORAGE_IMAGE);
		draw_image_descriptor_layout = BuildDescriptorLayout(*builder, device, .COMPUTE_BIT);
	}
	
	draw_image_descriptors = 
		AllocateDescriptorSet(*global_descriptor_allocator, device, draw_image_descriptor_layout);
		
	img_info: VkDescriptorImageInfo;
	img_info.imageLayout = .GENERAL;
	img_info.imageView = draw_image.image_view;
	
	draw_image_write: VkWriteDescriptorSet;
	draw_image_write.dstSet = draw_image_descriptors;
	draw_image_write.descriptorCount = 1;
	draw_image_write.descriptorType = .STORAGE_IMAGE;
	draw_image_write.pImageInfo = *img_info;
	
	vkUpdateDescriptorSets(device, 1, *draw_image_write, 0, null);
}

LoadShaderModuleFromBytes :: (bytes: [] u8, device: VkDevice) -> VkShaderModule, bool
{
	buffer := cast(*u32) bytes.data;
	
	create_info: VkShaderModuleCreateInfo;
	create_info.codeSize = xx bytes.count;
	create_info.pCode = buffer;
	
	shader_module: VkShaderModule;
	result := vkCreateShaderModule(device, *create_info, null, *shader_module);
	
	return shader_module, result == .SUCCESS;
}

InitPipelines :: (vulkan_engine: *VulkanEngine)
{
	InitBackgroudPipeline(vulkan_engine);
}

InitBackgroudPipeline :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	push_constants: VkPushConstantRange;
	push_constants.size = size_of(ComputePushConstants);
	push_constants.stageFlags = .COMPUTE_BIT;
	
	compute_layout: VkPipelineLayoutCreateInfo;
	compute_layout.pSetLayouts = *draw_image_descriptor_layout;
	compute_layout.setLayoutCount = 1;
	compute_layout.pPushConstantRanges = *push_constants;
	compute_layout.pushConstantRangeCount = 1;
	
	result := vkCreatePipelineLayout(device, *compute_layout, null, *background_effect.layout);
	assert(result == .SUCCESS, "Could not create pipeline layout.");
	
	SHADER_FILE, SHADER_FILE_LOADED :: #run read_entire_file("src/shaders/gradient_color.comp.spv");
	#assert(SHADER_FILE_LOADED);
	
	compute_draw_shader, shader_module_loaded := 
		LoadShaderModuleFromBytes(cast([] u8) SHADER_FILE, device);
	assert(shader_module_loaded, "Could not load shader module.");
	
	stage_info: VkPipelineShaderStageCreateInfo;
	stage_info.stage = .COMPUTE_BIT;
	stage_info.module = compute_draw_shader;
	stage_info.pName = "main";
	
	compute_pipeline_create_info: VkComputePipelineCreateInfo;
	compute_pipeline_create_info.layout = background_effect.layout;
	compute_pipeline_create_info.stage = stage_info;
	
	background_effect.name = "Gradient";
	background_effect.data.data1 = Vector4.{1, 0, 0, 1};
	background_effect.data.data2 = Vector4.{0, 0, 1, 1};
	
	result = vkCreateComputePipelines(
		device, null, 1, *compute_pipeline_create_info, null, *background_effect.pipeline);
		
	vkDestroyShaderModule(device, compute_draw_shader, null);
}

ResizeSwapchain :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	vkDeviceWaitIdle(device);
	
	width, height: s32;
	SDL_GetWindowSize(window, *width, *height);
	
	window_extent.width = xx width;
	window_extent.height = xx height;
	
	DestroySwapchain(vulkan_engine);
	// TODO : Optionally pass old swapchain when creating new one
	CreateSwapchain(vulkan_engine);
	CreateSwapchainImageViews(vulkan_engine);
	
	resize_requested = false;
}

GetBiggestDisplaySize :: () -> u32, u32
{
	width: u32;
	height: u32;
	for i: 0..SDL_GetNumVideoDisplays() - 1
	{
		display_mode_count := SDL_GetNumDisplayModes(i);
		if display_mode_count < 1 
		{
			log("SDL_GetNumDisplayModes failed: %\n", to_string(SDL_GetError()));
			return 0, 0;
		}

		
		for j: 0..display_mode_count - 1
		{
			mode: SDL_DisplayMode;
			if SDL_GetDisplayMode(i, j, *mode) != 0
			{
				log("SDL_GetDisplayMode failed: %\n", to_string(SDL_GetError()));
				return 0, 0;
			}

			if xx mode.w > width 
			{
				width = xx mode.w;
				height = xx mode.h;
			}
		}
	}

	return width, height;
}

CreateDrawImage :: (vulkan_engine: *VulkanEngine)
{
	using vulkan_engine;
	
	display_width, display_height := GetBiggestDisplaySize();
	assert(display_width > 0 && display_height > 0, "Could not get the biggest display size");
	
	draw_image_extent := VkExtent3D.{display_width, display_height, 1};
	draw_image.image_format = .R16G16B16A16_SFLOAT;
	draw_image.image_extent = draw_image_extent;
	
	draw_image_usages: VkImageUsageFlags = 
		.TRANSFER_SRC_BIT |
		.TRANSFER_DST_BIT |
		.STORAGE_BIT |
		.COLOR_ATTACHMENT_BIT;
		
	image_info := ImageCreateInfo(draw_image.image_format, draw_image_usages, draw_image_extent);
	
	image_alloc_info: VmaAllocationCreateInfo;
	image_alloc_info.usage = .GPU_ONLY;
	image_alloc_info.requiredFlags = .DEVICE_LOCAL_BIT;
	
	result := vmaCreateImage(
		gpu_allocator, 
		*image_info, 
		*image_alloc_info, 
		*draw_image.image, 
		*draw_image.allocation, 
		null
	);
	assert(result == .SUCCESS, "Failed to allocate image: %", result);
	
	view_info := ImageViewCreateInfo(draw_image.image_format, draw_image.image, .COLOR_BIT);
	
	result = vkCreateImageView(device, *view_info, null, *draw_image.image_view);
	assert(result == .SUCCESS, "Failed to create image view");
}

ComputePushConstants :: struct
{
	data1: Vector4;
	data2: Vector4;
	data3: Vector4;
	data4: Vector4;
}

ComputeEffect :: struct
{
	name: string;
	pipeline: VkPipeline;
	layout: VkPipelineLayout;
	data: ComputePushConstants;
}
