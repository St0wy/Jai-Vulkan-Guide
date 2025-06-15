
ImGui_ImplVulkan_InitInfo :: struct
{
	Instance: VkInstance;
	PhysicalDevice: VkPhysicalDevice;
	Device: VkDevice;
	QueueFamily: u32;
	Queue: VkQueue;
	DescriptorPool: VkDescriptorPool;
	RenderPass: VkRenderPass;
	MinImageCount: u32;
	ImageCount: u32;
	MSAASamples: VkSampleCountFlagBits;
	
	PipelineCache: VkPipelineCache;
	Subpass: u32;
	
	UseDynamicRendering: bool;
	
	#if IMGUI_IMPL_VULKAN_HAS_DYNAMIC_RENDERING 
	{
		PipelineRenderingCreateInfo: VkPipelineRenderingCreateInfoKHR;
	}
	
	Allocator: *VkAllocationCallbacks;
	CheckVkResultFn: #type (err: VkResult);
	MinAllocationSize: VkDeviceSize;
}

ImGui_ImplVulkan_Init :: (info: *ImGui_ImplVulkan_InitInfo) -> bool
{
	io := ImGui.GetIO();
	assert(io.BackendRendererUserData == null, "Already initialized a renderer backend!");
	
	bd := New(ImGui_ImplVulkan_Data);
	io.BackendRendererUserData = bd;
	io.BackendRendererName = "imgui_impl_vulkan";
	// We can honor the ImDrawCmd::VtxOffset field, allowing for large meshes.
    io.BackendFlags_ |= .RendererHasVtxOffset;  
    // We can create multi-viewports on the Renderer side (optional)
    io.BackendFlags_ |= .RendererHasViewports;  
    
    assert(info.Instance != VK_NULL_HANDLE);
    assert(info.PhysicalDevice != VK_NULL_HANDLE);
    assert(info.Device != VK_NULL_HANDLE);
    assert(info.Queue != VK_NULL_HANDLE);
    assert(info.DescriptorPool != VK_NULL_HANDLE);
    assert(info.MinImageCount >= 2);
    assert(info.ImageCount >= info.MinImageCount, tprint("image count : %, min image count: %\n", info.ImageCount, info.MinImageCount));
    if (info.UseDynamicRendering == false)
        assert(info.RenderPass != VK_NULL_HANDLE);
        
    bd.VulkanInitInfo = <<info;
    
    ImGui_ImplVulkan_CreateDeviceObjects();
    
	// main_viewport := ImGui.GetMainViewport();
	// main_viewport.RendererUserData = New(ImGui_ImplVulkan_ViewportData);

	// if (io.ConfigFlags_ & .ViewportsEnable)
	//     ImGui_ImplVulkan_InitPlatformInterface();

    return true;
}

ImGui_ImplVulkan_Shutdown :: ()
{
	bd := ImGui_ImplVulkan_GetBackendData();
	assert(bd != null, "No renderer backend to shutdown, or already shutdown?");
	io := ImGui.GetIO();
	v := *bd.VulkanInitInfo;
	
	for i: 0..bd.MainWindowRenderBuffers.Count - 1
	{
		ImGui_ImplVulkan_DestroyFrameRenderBuffers(v.Device, *bd.MainWindowRenderBuffers.FrameRenderBuffers[i], v.Allocator);
	}
	free(bd.MainWindowRenderBuffers.FrameRenderBuffers);
	
	ImGui_ImplVulkan_DestroyDeviceObjects();
	main_viewport := ImGui.GetMainViewport();
	
	// vd := cast(*ImGui_ImplVulkan_ViewportData) main_viewport.RendererUserData;
	// if vd then free(vd);
	// main_viewport.RendererUserData = null;
	
	ImGui_ImplVulkan_ShutdownPlatformInterface();

    io.BackendRendererName = null;
    io.BackendRendererUserData = null;
    io.BackendFlags_ &= ~(.RendererHasVtxOffset | .RendererHasViewports);
    free(bd);
}

ImGui_ImplVulkan_NewFrame :: ()
{
	bd := ImGui_ImplVulkan_GetBackendData();
	assert(bd != null, "Context or backend not initialized! Did you call ImGui_ImplVulkan_Init()?");
	
	if !bd.FontDescriptorSet then ImGui_ImplVulkan_CreateFontsTexture();
}

ImGui_ImplVulkan_RenderDrawData :: (
	draw_data: *ImGui.ImDrawData, 
	command_buffer: VkCommandBuffer, 
	pipeline: VkPipeline = VK_NULL_HANDLE
)
{
	fb_width := cast(s32)(draw_data.DisplaySize.x * draw_data.FramebufferScale.x);
	fb_height := cast(s32)(draw_data.DisplaySize.y * draw_data.FramebufferScale.y);
	if fb_width <= 0 || fb_height <= 0 then return;
	
	bd := ImGui_ImplVulkan_GetBackendData();
	v := bd.VulkanInitInfo;
	if pipeline == VK_NULL_HANDLE then pipeline = bd.Pipeline;
	
	wrb := *bd.MainWindowRenderBuffers;
	if wrb.FrameRenderBuffers == null
	{
		wrb.Index = 0;
		wrb.Count = v.ImageCount;
		wrb.FrameRenderBuffers = alloc(size_of(ImGui_ImplVulkan_FrameRenderBuffers) * wrb.Count);
		memset(wrb.FrameRenderBuffers, 0, size_of(ImGui_ImplVulkan_FrameRenderBuffers) * wrb.Count);
	}
	assert(wrb.Count == v.ImageCount);
	wrb.Index = (wrb.Index + 1) % wrb.Count;
	rb := *wrb.FrameRenderBuffers[wrb.Index];
	
	if draw_data.TotalVtxCount > 0
	{
		vertex_size := AlignBufferSize(cast(u64) draw_data.TotalVtxCount * size_of(ImGui.ImDrawVert), bd.BufferMemoryAlignment);
		index_size := AlignBufferSize(cast(u64) draw_data.TotalIdxCount * size_of(ImGui.ImDrawIdx), bd.BufferMemoryAlignment);
		
		if rb.VertexBuffer == VK_NULL_HANDLE || rb.VertexBufferSize < vertex_size
			CreateOrResizeBuffer(*rb.VertexBuffer, *rb.VertexBufferMemory, *rb.VertexBufferSize, vertex_size, .VERTEX_BUFFER_BIT);
		
		if rb.IndexBuffer == VK_NULL_HANDLE || rb.IndexBufferSize < index_size
			CreateOrResizeBuffer(*rb.IndexBuffer, *rb.IndexBufferMemory, *rb.IndexBufferSize, index_size, .INDEX_BUFFER_BIT);
			
		vtx_dst: *ImGui.ImDrawVert;
		idx_dst: *ImGui.ImDrawIdx;
		
		err := vkMapMemory(v.Device, rb.VertexBufferMemory, 0, vertex_size, 0, cast(**void)*vtx_dst);
		check_vk_result(err);
		
		err = vkMapMemory(v.Device, rb.IndexBufferMemory, 0, index_size, 0, cast(**void)*idx_dst);
		check_vk_result(err);
		
		for draw_data.CmdLists
		{
			memcpy(vtx_dst, it.VtxBuffer.Data, it.VtxBuffer.Size * size_of(ImGui.ImDrawVert));
			memcpy(idx_dst, it.IdxBuffer.Data, it.IdxBuffer.Size * size_of(ImGui.ImDrawIdx));
			vtx_dst += it.VtxBuffer.Size;
			idx_dst += it.IdxBuffer.Size;
		}
		
		range: [2] VkMappedMemoryRange;
		range[0].memory = rb.VertexBufferMemory;
		range[0].size = VK_WHOLE_SIZE;
		range[1].memory = rb.IndexBufferMemory;
		range[1].size = VK_WHOLE_SIZE;
		
		err = vkFlushMappedMemoryRanges(v.Device, range.count, range.data);
		check_vk_result(err);
		
		vkUnmapMemory(v.Device, rb.VertexBufferMemory);
		vkUnmapMemory(v.Device, rb.IndexBufferMemory);
	}
	
	ImGui_ImplVulkan_SetupRenderState(draw_data, pipeline, command_buffer, rb, fb_width, fb_height);
	
	clip_off := draw_data.DisplayPos;
	clip_scale := draw_data.FramebufferScale;
	
	global_vtx_offset: s32;
	global_idx_offset: s32;
	for cmd_list: draw_data.CmdLists
	{
		for pcmd: cmd_list.CmdBuffer
		{
			if pcmd.UserCallback != null
			{
				if pcmd.UserCallback == xx ImDrawCallback_ResetRenderState
					ImGui_ImplVulkan_SetupRenderState(draw_data, pipeline, command_buffer, rb, fb_width, fb_height);
				else
					pcmd.UserCallback(cmd_list, *pcmd);
			}
			else
			{
				clip_min := ImGui.ImVec2.{
					(pcmd.ClipRect.x - clip_off.x) * clip_scale.x, 
					(pcmd.ClipRect.y - clip_off.y) * clip_scale.y
				};
				
				clip_max := ImGui.ImVec2.{
					(pcmd.ClipRect.z - clip_off.x) * clip_scale.x, 
					(pcmd.ClipRect.w - clip_off.y) * clip_scale.y
				};
				
				if clip_min.x < 0.0 then clip_min.x = 0.0;
				if clip_min.y < 0.0 then clip_min.y = 0.0;
				if clip_max.x > xx fb_width then clip_max.x = xx fb_width;
				if clip_max.y > xx fb_height then clip_max.y = xx fb_height;
				if clip_max.x <= clip_min.x || clip_max.y <= clip_min.y then continue;
				
				scissor: VkRect2D;
				scissor.offset.x = xx clip_min.x;
				scissor.offset.y = xx clip_min.y;
				scissor.extent.width = xx (clip_max.x - clip_min.x);
				scissor.extent.height = xx (clip_max.y - clip_min.y);
				vkCmdSetScissor(command_buffer, 0, 1, *scissor);
				
				desc_set := VkDescriptorSet.[cast(VkDescriptorSet) pcmd.TextureId];
				#if size_of(ImGui.ImTextureID) < size_of(ImGui.ImU64)
				{
					assert(pcmd.TextureId == cast(ImGui.ImTextureID) bd.FontDescriptorSet);
					desc_set[0] = bd.FontDescriptorSet;
				}
				
				vkCmdBindDescriptorSets(command_buffer, .GRAPHICS, bd.PipelineLayout, 0, 1, desc_set.data, 0, null);
				
				index_offset: u32 = pcmd.IdxOffset + xx global_idx_offset;
				vertex_offset: s32 = (xx pcmd.VtxOffset) + global_vtx_offset;
				vkCmdDrawIndexed(
					command_buffer, 
					pcmd.ElemCount, 
					1, 
					index_offset, 
					vertex_offset, 
					0
				);
			}
		}
		
		global_idx_offset += cmd_list.IdxBuffer.Size;
		global_vtx_offset += cmd_list.VtxBuffer.Size;
	}
	
	scissor := VkRect2D.{.{0, 0}, .{xx fb_width, xx fb_height}};
	vkCmdSetScissor(command_buffer, 0, 1, *scissor);
}

ImGui_ImplVulkan_CreateFontsTexture :: () -> bool
{
	io := ImGui.GetIO();
	bd := ImGui_ImplVulkan_GetBackendData();
	v := *bd.VulkanInitInfo;
	err: VkResult;
	
	if bd.FontView || bd.FontImage || bd.FontMemory || bd.FontDescriptorSet
	{
		vkQueueWaitIdle(v.Queue);
		ImGui_ImplVulkan_DestroyFontsTexture();
	}
	
	if bd.FontCommandPool == VK_NULL_HANDLE
	{
		info: VkCommandPoolCreateInfo;
		info.queueFamilyIndex = v.QueueFamily;
		err = vkCreateCommandPool(v.Device, *info, v.Allocator, *bd.FontCommandPool);
		check_vk_result(err);
	}
	
	if bd.FontCommandBuffer == VK_NULL_HANDLE
	{
		info: VkCommandBufferAllocateInfo;
		info.commandPool = bd.FontCommandPool;
		info.commandBufferCount = 1;
		err = vkAllocateCommandBuffers(v.Device, *info, *bd.FontCommandBuffer);
		check_vk_result(err);
	}
	
	{
		err = vkResetCommandPool(v.Device, bd.FontCommandPool, 0);
		check_vk_result(err);
		begin_info: VkCommandBufferBeginInfo;
		begin_info.flags |= .ONE_TIME_SUBMIT_BIT;
		err = vkBeginCommandBuffer(bd.FontCommandBuffer, *begin_info);
		check_vk_result(err);
	}
	
	pixels: *u8;
	width, height: s32;
	
	ImGui.ImFontAtlas.GetTexDataAsRGBA32(io.Fonts, *pixels, *width, *height);
	upload_size: u64 = cast(u64) width * cast(u64) height * 4 * size_of(u8);
	
	{
		info: VkImageCreateInfo;
		info.imageType = ._2D;
		info.format = .R8G8B8A8_UNORM;
		info.extent.width = xx width;
		info.extent.height = xx height;
		info.extent.depth = 1;
		info.mipLevels = 1;
		info.arrayLayers = 1;
		info.samples = ._1_BIT;
		info.tiling = .OPTIMAL;
		info.usage = .SAMPLED_BIT | .TRANSFER_DST_BIT;
		info.sharingMode = .EXCLUSIVE;
		info.initialLayout = .UNDEFINED;
		err = vkCreateImage(v.Device, *info, v.Allocator, *bd.FontImage);
		check_vk_result(err);
		
		req: VkMemoryRequirements;
		vkGetImageMemoryRequirements(v.Device, bd.FontImage, *req);
		
		alloc_info: VkMemoryAllocateInfo;
		alloc_info.allocationSize = max(v.MinAllocationSize, req.size);
		alloc_info.memoryTypeIndex = ImGui_ImplVulkan_MemoryType(.DEVICE_LOCAL_BIT, req.memoryTypeBits);
		err = vkAllocateMemory(v.Device, *alloc_info, v.Allocator, *bd.FontMemory);
		check_vk_result(err);
		
		err = vkBindImageMemory(v.Device, bd.FontImage, bd.FontMemory, 0);
		check_vk_result(err);
	}
	
	{
		info: VkImageViewCreateInfo;
		info.image = bd.FontImage;
		info.viewType = ._2D;
		info.format = .R8G8B8A8_UNORM;
		info.subresourceRange.aspectMask = .COLOR_BIT;
		info.subresourceRange.levelCount = 1;
		info.subresourceRange.layerCount = 1;
		err = vkCreateImageView(v.Device, *info, v.Allocator, *bd.FontView);
		check_vk_result(err);
	}
	
	bd.FontDescriptorSet = cast(VkDescriptorSet) ImGui_ImplVulkan_AddTexture(bd.FontSampler, bd.FontView, .SHADER_READ_ONLY_OPTIMAL);
	
	upload_buffer_memory: VkDeviceMemory;
	upload_buffer: VkBuffer;
	{
		buffer_info: VkBufferCreateInfo;
		buffer_info.size = upload_size;
		buffer_info.usage = .TRANSFER_SRC_BIT;
		buffer_info.sharingMode = .EXCLUSIVE;
		err = vkCreateBuffer(v.Device, *buffer_info, v.Allocator, *upload_buffer);
		check_vk_result(err);
		
		req: VkMemoryRequirements;
		vkGetBufferMemoryRequirements(v.Device, upload_buffer, *req);
		bd.BufferMemoryAlignment = ifx bd.BufferMemoryAlignment > req.alignment then bd.BufferMemoryAlignment else req.alignment;
		
		alloc_info: VkMemoryAllocateInfo;
		alloc_info.allocationSize = max(v.MinAllocationSize, req.size);
		alloc_info.memoryTypeIndex = ImGui_ImplVulkan_MemoryType(.HOST_VISIBLE_BIT, req.memoryTypeBits);
		err = vkAllocateMemory(v.Device, *alloc_info, v.Allocator, *upload_buffer_memory);
		check_vk_result(err);
		
		err = vkBindBufferMemory(v.Device, upload_buffer, upload_buffer_memory, 0);
		check_vk_result(err);
	}
	
	{
		map: *u8;
		err = vkMapMemory(v.Device, upload_buffer_memory, 0, upload_size, 0, cast(**void)(*map));
		check_vk_result(err);
		
		memcpy(map, pixels, xx upload_size);
		
		range: [1] VkMappedMemoryRange;
		range[0].memory = upload_buffer_memory;
		range[0].size = upload_size;
		
		err = vkFlushMappedMemoryRanges(v.Device, 1, range.data);
		check_vk_result(err);
		
		vkUnmapMemory(v.Device, upload_buffer_memory);
	}
	
	{
		copy_barrier: [1] VkImageMemoryBarrier;
		copy_barrier[0].dstAccessMask = .TRANSFER_WRITE_BIT;
        copy_barrier[0].oldLayout = .UNDEFINED;
        copy_barrier[0].newLayout = .TRANSFER_DST_OPTIMAL;
        copy_barrier[0].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        copy_barrier[0].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        copy_barrier[0].image = bd.FontImage;
        copy_barrier[0].subresourceRange.aspectMask = .COLOR_BIT;
        copy_barrier[0].subresourceRange.levelCount = 1;
        copy_barrier[0].subresourceRange.layerCount = 1;
        vkCmdPipelineBarrier(bd.FontCommandBuffer, .HOST_BIT, .TRANSFER_BIT, 0, 0, null, 0, null, 1, copy_barrier.data);
        
        region: VkBufferImageCopy;
        region.imageSubresource.aspectMask = .COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent.width = xx width;
        region.imageExtent.height = xx height;
        region.imageExtent.depth = 1;
        vkCmdCopyBufferToImage(bd.FontCommandBuffer, upload_buffer, bd.FontImage, .TRANSFER_DST_OPTIMAL, 1, *region);
        
        use_barrier: [1] VkImageMemoryBarrier;
        use_barrier[0].sType = .IMAGE_MEMORY_BARRIER;
        use_barrier[0].srcAccessMask = .TRANSFER_WRITE_BIT;
        use_barrier[0].dstAccessMask = .SHADER_READ_BIT;
        use_barrier[0].oldLayout = .TRANSFER_DST_OPTIMAL;
        use_barrier[0].newLayout = .SHADER_READ_ONLY_OPTIMAL;
        use_barrier[0].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        use_barrier[0].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        use_barrier[0].image = bd.FontImage;
        use_barrier[0].subresourceRange.aspectMask = .COLOR_BIT;
        use_barrier[0].subresourceRange.levelCount = 1;
        use_barrier[0].subresourceRange.layerCount = 1;
        vkCmdPipelineBarrier(bd.FontCommandBuffer, .TRANSFER_BIT, .FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, use_barrier.data);
	}
	
	io.Fonts.TexID = cast(ImGui.ImTextureID) bd.FontDescriptorSet;
	
	end_info: VkSubmitInfo;
	end_info.commandBufferCount = 1;
	end_info.pCommandBuffers = *bd.FontCommandBuffer;
	err = vkEndCommandBuffer(bd.FontCommandBuffer);
	check_vk_result(err);
	
	err = vkQueueSubmit(v.Queue, 1, *end_info, VK_NULL_HANDLE);
	check_vk_result(err);
	
	err = vkQueueWaitIdle(v.Queue);
	check_vk_result(err);
	
	vkDestroyBuffer(v.Device, upload_buffer, v.Allocator);
	vkFreeMemory(v.Device, upload_buffer_memory, v.Allocator);
	
	return true;
}

ImGui_ImplVulkan_DestroyFontsTexture :: ()
{
	io := ImGui.GetIO();
	bd := ImGui_ImplVulkan_GetBackendData();
	v := *bd.VulkanInitInfo;
	
	if bd.FontDescriptorSet
	{
		ImGui_ImplVulkan_RemoveTexture(bd.FontDescriptorSet);
		bd.FontDescriptorSet = VK_NULL_HANDLE;
		io.Fonts.TexID = 0;
	}
	
	if bd.FontView 
	{
		vkDestroyImageView(v.Device, bd.FontView, v.Allocator);
		bd.FontView = VK_NULL_HANDLE;
	}
	
	if bd.FontImage
	{
		vkDestroyImage(v.Device, bd.FontImage, v.Allocator);
		bd.FontImage = VK_NULL_HANDLE;
	}
	
	if bd.FontMemory
	{
		vkFreeMemory(v.Device, bd.FontMemory, v.Allocator);
		bd.FontMemory = VK_NULL_HANDLE;
	}
}

ImGui_ImplVulkan_SetMinImageCount :: (min_image_count: u32)
{
	bd := ImGui_ImplVulkan_GetBackendData();
	assert(min_image_count >= 2);
	if bd.VulkanInitInfo.MinImageCount == min_image_count then return;
	
	// That's what the C++ does...
	assert(false, "FIXME-VIEWPORT: Unsupported. Need to recreate all swap chains!");
	
	v := bd.VulkanInitInfo;
	err := vkDeviceWaitIdle(v.Device);
	check_vk_result(err);
	
	// ImGui_ImplVulkanH_DestroyAllViewportsRenderBuffers(v.Device, v.Allocator);
	
	bd.VulkanInitInfo.MinImageCount = min_image_count;
}

ImGui_ImplVulkan_AddTexture :: (
	sampler: VkSampler, 
	image_view: VkImageView, 
	image_layout: VkImageLayout
) -> VkDescriptorSet
{
	bd := ImGui_ImplVulkan_GetBackendData();
	v := *bd.VulkanInitInfo;
	
	descriptor_set: VkDescriptorSet;
	{
		alloc_info: VkDescriptorSetAllocateInfo;
		alloc_info.descriptorPool = v.DescriptorPool;
        alloc_info.descriptorSetCount = 1;
        alloc_info.pSetLayouts = *bd.DescriptorSetLayout;
        err := vkAllocateDescriptorSets(v.Device, *alloc_info, *descriptor_set);
        check_vk_result(err);
	}
	
	{
		desc_image: [1] VkDescriptorImageInfo;
		desc_image[0].sampler = sampler;
        desc_image[0].imageView = image_view;
        desc_image[0].imageLayout = image_layout;
        
        write_desc: [1] VkWriteDescriptorSet;
        write_desc[0].dstSet = descriptor_set;
        write_desc[0].descriptorCount = 1;
        write_desc[0].descriptorType = .COMBINED_IMAGE_SAMPLER;
        write_desc[0].pImageInfo = desc_image.data;
        vkUpdateDescriptorSets(v.Device, 1, write_desc.data, 0, null);
	}
	
	return descriptor_set;
}

ImGui_ImplVulkan_RemoveTexture :: (descriptor_set: VkDescriptorSet)
{
	bd := ImGui_ImplVulkan_GetBackendData();
	v := *bd.VulkanInitInfo;
	vkFreeDescriptorSets(v.Device, v.DescriptorPool, 1, *descriptor_set);
}

#scope_file

IMGUI_IMPL_VULKAN_HAS_DYNAMIC_RENDERING :: VK_VERSION_1_3 || VK_KHR_dynamic_rendering;
ImDrawCallback_ResetRenderState :: -8;

ImGui_ImplVulkan_FrameRenderBuffers :: struct
{
	VertexBufferMemory: VkDeviceMemory;
	IndexBufferMemory: VkDeviceMemory;
	VertexBufferSize: VkDeviceSize;
    IndexBufferSize: VkDeviceSize;
    VertexBuffer: VkBuffer;
    IndexBuffer: VkBuffer;
}

ImGui_ImplVulkan_WindowRenderBuffers :: struct
{
	Index: u32;
	Count: u32;
	FrameRenderBuffers: *ImGui_ImplVulkan_FrameRenderBuffers;
}

ImGui_ImplVulkan_Data :: struct
{
	VulkanInitInfo: ImGui_ImplVulkan_InitInfo;
    BufferMemoryAlignment: VkDeviceSize;
    PipelineCreateFlags: VkPipelineCreateFlags;
    DescriptorSetLayout: VkDescriptorSetLayout;
    PipelineLayout: VkPipelineLayout;
    Pipeline: VkPipeline;
    // pipeline for secondary viewports (created by backend)
	// VkPipeline PipelineForViewports;
    ShaderModuleVert: VkShaderModule;
    ShaderModuleFrag: VkShaderModule;

    // Font data
    FontSampler: VkSampler;
    FontMemory: VkDeviceMemory;
    FontImage: VkImage;
    FontView: VkImageView;
    FontDescriptorSet: VkDescriptorSet;
    FontCommandPool: VkCommandPool;
    FontCommandBuffer: VkCommandBuffer;

    // Render buffers for main window
    MainWindowRenderBuffers: ImGui_ImplVulkan_WindowRenderBuffers;
    
    BufferMemoryAlignment = 256;
}

__glsl_shader_vert_spv, VERT_LOADED :: 
	#run read_entire_file("src/imgui_backends/vulkan/glsl_shader.vert.spv");
#assert(VERT_LOADED);
	
__glsl_shader_frag_spv, FRAG_LOADED :: 
	#run read_entire_file("src/imgui_backends/vulkan/glsl_shader.frag.spv");
#assert(FRAG_LOADED);

ImGui_ImplVulkan_GetBackendData :: () -> *ImGui_ImplVulkan_Data
{
	return ifx ImGui.GetCurrentContext() then 
		cast(*ImGui_ImplVulkan_Data) ImGui.GetIO().BackendRendererUserData
	else
		null;
}

ImGui_ImplVulkan_MemoryType :: (properties: VkMemoryPropertyFlags, type_bits: u32) -> u32
{
	bd := ImGui_ImplVulkan_GetBackendData();
	v := *bd.VulkanInitInfo;
	prop: VkPhysicalDeviceMemoryProperties;
	vkGetPhysicalDeviceMemoryProperties(v.PhysicalDevice, *prop);
	for i: 0..prop.memoryTypeCount - 1
	{
		if (prop.memoryTypes[i].propertyFlags & properties) == properties && type_bits & (1 << i)
			return i;
	}
	
	return 0xFFFF_FFFF;
}

check_vk_result :: (err: VkResult)
{
	bd := ImGui_ImplVulkan_GetBackendData();
	if !bd then return;
	v := *bd.VulkanInitInfo;
	if v.CheckVkResultFn then v.CheckVkResultFn(err);
}

AlignBufferSize :: (size: VkDeviceSize, alignment: VkDeviceSize) -> VkDeviceSize
{
	return (size + alignment - 1) & ~(alignment - 1);
}

// The C++ code uses non-const references, so idk if using a pointer in this case 
// is a good equivalent for the parameters
CreateOrResizeBuffer :: (
	buffer: *VkBuffer, 
	buffer_memory: *VkDeviceMemory, 
	buffer_size: *VkDeviceSize,
	new_size: u64,
	usage: VkBufferUsageFlagBits
)
{
	bd := ImGui_ImplVulkan_GetBackendData();
	v := *bd.VulkanInitInfo;
	err: VkResult;
	if <<buffer != VK_NULL_HANDLE
	{
		vkDestroyBuffer(v.Device, <<buffer, v.Allocator);
	}
	if <<buffer_memory != VK_NULL_HANDLE 
	{
		vkFreeMemory(v.Device, <<buffer_memory, v.Allocator);
	}
	
	buffer_size_aligned := 
		AlignBufferSize(max(v.MinAllocationSize, new_size), bd.BufferMemoryAlignment);
		
	buffer_info: VkBufferCreateInfo;
	buffer_info.size = buffer_size_aligned;
	buffer_info.usage = usage;
	buffer_info.sharingMode = .EXCLUSIVE;
	err = vkCreateBuffer(v.Device, *buffer_info, v.Allocator, buffer);
	check_vk_result(err);
	
	req: VkMemoryRequirements;
	vkGetBufferMemoryRequirements(v.Device, <<buffer, *req);
	bd.BufferMemoryAlignment = ifx bd.BufferMemoryAlignment > req.alignment then 
		bd.BufferMemoryAlignment 
	else 
		req.alignment;
		
	alloc_info: VkMemoryAllocateInfo;
	alloc_info.allocationSize = req.size;
	alloc_info.memoryTypeIndex = ImGui_ImplVulkan_MemoryType(.HOST_VISIBLE_BIT, req.memoryTypeBits);
	err = vkAllocateMemory(v.Device, *alloc_info, v.Allocator, buffer_memory);
	check_vk_result(err);
	
	err = vkBindBufferMemory(v.Device, <<buffer, <<buffer_memory, 0);
	check_vk_result(err);
	<<buffer_size = buffer_size_aligned;
}

ImGui_ImplVulkan_SetupRenderState :: (
	draw_data: *ImGui.ImDrawData, 
	pipeline: VkPipeline, 
	command_buffer: VkCommandBuffer,
	rb: *ImGui_ImplVulkan_FrameRenderBuffers,
	fb_width: s32,
	fb_height: s32
)
{
	bd := ImGui_ImplVulkan_GetBackendData();
	
	vkCmdBindPipeline(command_buffer, .GRAPHICS, pipeline);
	
	if draw_data.TotalVtxCount > 0
	{
		vertex_buffers := VkBuffer.[rb.VertexBuffer];
		vertex_offset := VkDeviceSize.[0];
		vkCmdBindVertexBuffers(command_buffer, 0, 1, vertex_buffers.data, vertex_offset.data);
		index_type :: #ifx size_of(ImGui.ImDrawIdx) == 2 then VkIndexType.UINT16 else VkIndexType.UINT32;
		vkCmdBindIndexBuffer(command_buffer, rb.IndexBuffer, 0, index_type);
	}
	
	viewport: VkViewport;
	viewport.width = cast(float32) fb_width;
	viewport.height = cast(float32) fb_height;
	viewport.maxDepth = 1.0;
	vkCmdSetViewport(command_buffer, 0, 1, *viewport);
	
	scale := float32.[2.0 / draw_data.DisplaySize.x, 2.0 / draw_data.DisplaySize.y];
	translate := float32.[
		-1.0 - draw_data.DisplayPos.x * scale[0], 
		-1.0 - draw_data.DisplayPos.y * scale[1]
	];
	vkCmdPushConstants(
		command_buffer, 
		bd.PipelineLayout, 
		.VERTEX_BIT, 
		size_of(float32) * 0,
		size_of(float32) * 2,
		scale.data
	);
	vkCmdPushConstants(
		command_buffer, 
		bd.PipelineLayout, 
		.VERTEX_BIT, 
		size_of(float32) * 2,
		size_of(float32) * 2,
		translate.data
	);
}

ImGui_ImplVulkan_CreateShaderModules :: (device: VkDevice, allocator: *VkAllocationCallbacks)
{
	bd := ImGui_ImplVulkan_GetBackendData();
	if bd.ShaderModuleVert == VK_NULL_HANDLE
	{
		buffer := cast(*u32) __glsl_shader_vert_spv.data;
		
		vert_info: VkShaderModuleCreateInfo;
		vert_info.codeSize = __glsl_shader_vert_spv.count;
		vert_info.pCode = buffer;
		
		err := vkCreateShaderModule(device, *vert_info, allocator, *bd.ShaderModuleVert);
		check_vk_result(err);
	}
	
	if bd.ShaderModuleFrag == VK_NULL_HANDLE
	{
		buffer := cast(*u32) __glsl_shader_frag_spv.data;
	
		frag_info: VkShaderModuleCreateInfo;
		frag_info.codeSize = __glsl_shader_frag_spv.count;
		frag_info.pCode = buffer;
		
		err := vkCreateShaderModule(device, *frag_info, allocator, *bd.ShaderModuleFrag);
		check_vk_result(err);
	}
}

ImGui_ImplVulkan_CreatePipeline :: (
	device: VkDevice, 
	allocator: *VkAllocationCallbacks, 
	pipelineCache: VkPipelineCache, 
	renderPass: VkRenderPass, 
	MSAASamples: VkSampleCountFlagBits, 
	pipeline: *VkPipeline, subpass: u32
)
{
	bd := ImGui_ImplVulkan_GetBackendData();
    ImGui_ImplVulkan_CreateShaderModules(device, allocator);
    
    stage: [2] VkPipelineShaderStageCreateInfo;
    stage[0].stage = .VERTEX_BIT;
    stage[0].module = bd.ShaderModuleVert;
    stage[0].pName = "main";
    stage[1].stage = .FRAGMENT_BIT;
    stage[1].module = bd.ShaderModuleFrag;
    stage[1].pName = "main";
    
    binding_desc: [1] VkVertexInputBindingDescription;
    binding_desc[0].stride = size_of(ImGui.ImDrawVert);
    binding_desc[0].inputRate = .VERTEX;
    
    attribute_desc: [3] VkVertexInputAttributeDescription;
    attribute_desc[0].location = 0;
    attribute_desc[0].binding = binding_desc[0].binding;
    attribute_desc[0].format = .R32G32_SFLOAT;
    attribute_desc[0].offset = xx offset_of(ImGui.ImDrawVert, #code pos);
    attribute_desc[1].location = 1;
    attribute_desc[1].binding = binding_desc[0].binding;
    attribute_desc[1].format = .R32G32_SFLOAT;
    attribute_desc[1].offset = xx offset_of(ImGui.ImDrawVert, #code uv);
    attribute_desc[2].location = 2;
    attribute_desc[2].binding = binding_desc[0].binding;
    attribute_desc[2].format = .R8G8B8A8_UNORM;
    attribute_desc[2].offset = xx offset_of(ImGui.ImDrawVert, #code col);
    
    vertex_info: VkPipelineVertexInputStateCreateInfo;
    vertex_info.vertexBindingDescriptionCount = 1;
    vertex_info.pVertexBindingDescriptions = binding_desc.data;
    vertex_info.vertexAttributeDescriptionCount = 3;
    vertex_info.pVertexAttributeDescriptions = attribute_desc.data;
    
    ia_info: VkPipelineInputAssemblyStateCreateInfo;
	ia_info.topology = .TRIANGLE_LIST;
	
	viewport_info: VkPipelineViewportStateCreateInfo;
	viewport_info.viewportCount = 1;
	viewport_info.scissorCount = 1;
    
    raster_info: VkPipelineRasterizationStateCreateInfo;
    raster_info.polygonMode = .FILL;
    raster_info.cullMode = .NONE;
    raster_info.frontFace = .COUNTER_CLOCKWISE;
    raster_info.lineWidth = 1.0;
    
    ms_info: VkPipelineMultisampleStateCreateInfo;
    ms_info.rasterizationSamples = ifx MSAASamples != 0 then MSAASamples else ._1_BIT;
    
    color_attachment: [1] VkPipelineColorBlendAttachmentState;
    color_attachment[0].blendEnable = VK_TRUE;
    color_attachment[0].srcColorBlendFactor = .SRC_ALPHA;
    color_attachment[0].dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA;
    color_attachment[0].colorBlendOp = .ADD;
    color_attachment[0].srcAlphaBlendFactor = .ONE;
    color_attachment[0].dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA;
    color_attachment[0].alphaBlendOp = .ADD;
    color_attachment[0].colorWriteMask = .R_BIT | .G_BIT | .B_BIT | .A_BIT;
    
    depth_info: VkPipelineDepthStencilStateCreateInfo;
    
    blend_info: VkPipelineColorBlendStateCreateInfo;
    blend_info.attachmentCount = 1;
    blend_info.pAttachments = color_attachment.data;
    
    dynamic_states := VkDynamicState.[.VIEWPORT, .SCISSOR];
    dynamic_state: VkPipelineDynamicStateCreateInfo;
    dynamic_state.dynamicStateCount = dynamic_states.count;
    dynamic_state.pDynamicStates = dynamic_states.data;
    
    info: VkGraphicsPipelineCreateInfo;
    info.flags = bd.PipelineCreateFlags;
    info.stageCount = 2;
    info.pStages = stage.data;
    info.pVertexInputState = *vertex_info;
    info.pInputAssemblyState = *ia_info;
    info.pViewportState = *viewport_info;
    info.pRasterizationState = *raster_info;
    info.pMultisampleState = *ms_info;
    info.pDepthStencilState = *depth_info;
    info.pColorBlendState = *blend_info;
    info.pDynamicState = *dynamic_state;
    info.layout = bd.PipelineLayout;
    info.renderPass = renderPass;
    info.subpass = subpass;
    
    #if IMGUI_IMPL_VULKAN_HAS_DYNAMIC_RENDERING
    {
    	if bd.VulkanInitInfo.UseDynamicRendering
    	{
    		assert(bd.VulkanInitInfo.PipelineRenderingCreateInfo.sType == .PIPELINE_RENDERING_CREATE_INFO_KHR, 
    			"PipelineRenderingCreateInfo sType must be VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO_KHR");
    		assert(bd.VulkanInitInfo.PipelineRenderingCreateInfo.pNext == null, "PipelineRenderingCreateInfo pNext must be null");
    		
    		info.pNext = *bd.VulkanInitInfo.PipelineRenderingCreateInfo;
    		info.renderPass = VK_NULL_HANDLE;
    	}
    }
    
    err := vkCreateGraphicsPipelines(device, pipelineCache, 1, *info, allocator, pipeline);
    check_vk_result(err);
}

ImGui_ImplVulkan_CreateDeviceObjects :: () -> bool
{
	bd := ImGui_ImplVulkan_GetBackendData();
	v := *bd.VulkanInitInfo;
	err: VkResult;
	
	if !bd.FontSampler
	{
		info: VkSamplerCreateInfo;
		info.magFilter = .LINEAR;
        info.minFilter = .LINEAR;
        info.mipmapMode = .LINEAR;
        info.addressModeU = .REPEAT;
        info.addressModeV = .REPEAT;
        info.addressModeW = .REPEAT;
        info.minLod = -1000;
        info.maxLod = 1000;
        info.maxAnisotropy = 1.0;
        err = vkCreateSampler(v.Device, *info, v.Allocator, *bd.FontSampler);
        check_vk_result(err);
	}
	
	if !bd.DescriptorSetLayout
	{
		binding: [1] VkDescriptorSetLayoutBinding;
		binding[0].descriptorType = .COMBINED_IMAGE_SAMPLER;
        binding[0].descriptorCount = 1;
        binding[0].stageFlags = .FRAGMENT_BIT;
        
        info: VkDescriptorSetLayoutCreateInfo; 
        info.bindingCount = 1;
        info.pBindings = binding.data;
        err = vkCreateDescriptorSetLayout(v.Device, *info, v.Allocator, *bd.DescriptorSetLayout);
        check_vk_result(err);
	}
	
	if !bd.PipelineLayout
	{
		push_constants: [1] VkPushConstantRange;
		push_constants[0].stageFlags = .VERTEX_BIT;
        push_constants[0].offset = size_of(float32) * 0;
        push_constants[0].size = size_of(float32) * 4;
        
        set_layout: [1] VkDescriptorSetLayout = VkDescriptorSetLayout.[ bd.DescriptorSetLayout ];
        
        layout_info: VkPipelineLayoutCreateInfo; 
        layout_info.setLayoutCount = 1;
        layout_info.pSetLayouts = set_layout.data;
        layout_info.pushConstantRangeCount = 1;
        layout_info.pPushConstantRanges = push_constants.data;
        err = vkCreatePipelineLayout(v.Device, *layout_info, v.Allocator, *bd.PipelineLayout);
        check_vk_result(err);
	}
	
	ImGui_ImplVulkan_CreatePipeline(v.Device, v.Allocator, v.PipelineCache, v.RenderPass, v.MSAASamples, *bd.Pipeline, v.Subpass);
	
	return true;
}

ImGui_ImplVulkan_DestroyDeviceObjects :: ()
{
	bd := ImGui_ImplVulkan_GetBackendData();
	v := *bd.VulkanInitInfo;
	
	// ImGui_ImplVulkanH_DestroyAllViewportsRenderBuffers(v.Device, v.Allocator);
    ImGui_ImplVulkan_DestroyFontsTexture();
    
    if bd.FontCommandBuffer
    {
    	vkFreeCommandBuffers(v.Device, bd.FontCommandPool, 1, *bd.FontCommandBuffer);
    	bd.FontCommandBuffer = VK_NULL_HANDLE;
    }
    
    if bd.FontCommandPool
    {
    	vkDestroyCommandPool(v.Device, bd.FontCommandPool, v.Allocator);
    	bd.FontCommandPool = VK_NULL_HANDLE;
    }
    
    if bd.ShaderModuleVert
    {
    	vkDestroyShaderModule(v.Device, bd.ShaderModuleVert, v.Allocator);
    	bd.ShaderModuleVert = VK_NULL_HANDLE;
    }
    
    if bd.ShaderModuleFrag
    {
    	vkDestroyShaderModule(v.Device, bd.ShaderModuleFrag, v.Allocator); 
    	bd.ShaderModuleFrag = VK_NULL_HANDLE;
    }
    
    if bd.FontSampler
    {
    	vkDestroySampler(v.Device, bd.FontSampler, v.Allocator);
    	bd.FontSampler = VK_NULL_HANDLE;
    }
    
    if bd.DescriptorSetLayout
    {
    	vkDestroyDescriptorSetLayout(v.Device, bd.DescriptorSetLayout, v.Allocator);
    	bd.DescriptorSetLayout = VK_NULL_HANDLE;
    }
    
    if bd.PipelineLayout
    {
    	vkDestroyPipelineLayout(v.Device, bd.PipelineLayout, v.Allocator);
    	bd.PipelineLayout = VK_NULL_HANDLE;
    }
    
    if bd.Pipeline
    {
    	vkDestroyPipeline(v.Device, bd.Pipeline, v.Allocator);
    	bd.Pipeline = VK_NULL_HANDLE;
    }
    
	// if bd.PipelineForViewports
	// {
	// 	vkDestroyPipeline(v.Device, bd.PipelineForViewports, v.Allocator);
	// 	bd.PipelineForViewports = VK_NULL_HANDLE;
	// }
}

// ImGui_ImplVulkanH_DestroyAllViewportsRenderBuffers :: (device: VkDevice, allocator: *VkAllocationCallbacks)
// {

// }

ImGui_ImplVulkan_ShutdownPlatformInterface :: ()
{
	ImGui.DestroyPlatformWindows();
}

ImGui_ImplVulkan_DestroyFrameRenderBuffers :: (
	device: VkDevice, 
	buffers: *ImGui_ImplVulkan_FrameRenderBuffers, 
	allocator: *VkAllocationCallbacks
)
{
	if buffers.VertexBuffer
	{
		vkDestroyBuffer(device, buffers.VertexBuffer, allocator);
		buffers.VertexBuffer = VK_NULL_HANDLE;
	}
	
	if buffers.VertexBufferMemory
	{
		vkFreeMemory(device, buffers.VertexBufferMemory, allocator);
		buffers.VertexBufferMemory = VK_NULL_HANDLE;
	}
	
	if buffers.IndexBuffer
	{
		vkDestroyBuffer(device, buffers.IndexBuffer, allocator);
		buffers.IndexBuffer = VK_NULL_HANDLE;
	}
	
	if buffers.IndexBufferMemory
	{
		vkFreeMemory(device, buffers.IndexBufferMemory, allocator);
		buffers.IndexBufferMemory = VK_NULL_HANDLE;
	}
	
	buffers.VertexBufferSize = 0;
    buffers.IndexBufferSize = 0;
}


