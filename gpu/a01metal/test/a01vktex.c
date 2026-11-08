/*
 * Galaxy A01 Core: texture sampling straight on the GE8100 Vulkan driver, without Zink.
 *
 * The iOS UI (Zink) and GL3/GL5-GL7 fail on every textured draw (TCU faults at garbage
 * addresses) while untextured draws are right. Two variants of the same draw tell the halves
 * apart:
 *   V1  2x2 OPTIMAL texture uploaded with vkCmdCopyBufferToImage (the way Zink uploads)
 *   V2  2x2 LINEAR texture written by the CPU through its mapping (no GPU upload at all)
 *   V3  no texture: the interpolated coordinate as the colour (V1/V2 read texel (0,0) everywhere)
 *   V4  a constant varying (0.5, 0.25), smooth     V5  the same constant, flat
 *   V6  gl_FragCoord / 64 as the colour (no varyings)
 * Both are sampled (NEAREST) by a fragment shader over a 64x64 LINEAR target that the CPU reads
 * directly (the GPU copy back also depends on per-pixel positions; its first pixel is reported too).
 * Texels: (0,0) red, (1,0) green, (0,1) blue, (1,1) white; each target quadrant shows one.
 */
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

#include "tex_spv.h"   /* tex_vert_spv, tex_frag_spv (build-a01metal.sh) */

#define VKP(x) static PFN_##x x##_
VKP(vkGetInstanceProcAddr); VKP(vkCreateInstance); VKP(vkEnumeratePhysicalDevices);
VKP(vkGetPhysicalDeviceMemoryProperties); VKP(vkCreateDevice); VKP(vkGetDeviceQueue);
VKP(vkCreateBuffer); VKP(vkGetBufferMemoryRequirements); VKP(vkAllocateMemory); VKP(vkBindBufferMemory);
VKP(vkMapMemory); VKP(vkCreateImage); VKP(vkGetImageMemoryRequirements); VKP(vkBindImageMemory);
VKP(vkGetImageSubresourceLayout); VKP(vkCreateImageView); VKP(vkCreateSampler); VKP(vkCreateDescriptorSetLayout);
VKP(vkCreateDescriptorPool); VKP(vkAllocateDescriptorSets); VKP(vkUpdateDescriptorSets);
VKP(vkCreatePipelineLayout); VKP(vkCreateShaderModule); VKP(vkCreateRenderPass); VKP(vkCreateFramebuffer);
VKP(vkCreateGraphicsPipelines); VKP(vkCreateCommandPool); VKP(vkAllocateCommandBuffers);
VKP(vkBeginCommandBuffer); VKP(vkEndCommandBuffer); VKP(vkCmdPipelineBarrier); VKP(vkCmdCopyBufferToImage);
VKP(vkCmdBeginRenderPass); VKP(vkCmdEndRenderPass); VKP(vkCmdBindPipeline); VKP(vkCmdBindDescriptorSets);
VKP(vkCmdDraw); VKP(vkCmdCopyImageToBuffer); VKP(vkQueueSubmit); VKP(vkQueueWaitIdle);

static VkInstance inst;
static VkPhysicalDevice phys;
static VkDevice dev;
static VkQueue queue;
static VkPhysicalDeviceMemoryProperties memp;
static uint8_t g_vt_copy0[4];

static int
mem_type(uint32_t bits, VkMemoryPropertyFlags want)
{
	for (uint32_t i = 0; i < memp.memoryTypeCount; i++) {
		if ((bits & (1u << i)) && (memp.memoryTypes[i].propertyFlags & want) == want) {
			return (int)i;
		}
	}
	return -1;
}

static VkDeviceMemory
alloc_for(VkMemoryRequirements req, VkMemoryPropertyFlags want)
{
	int t = mem_type(req.memoryTypeBits, want);
	if (t < 0) {
		t = mem_type(req.memoryTypeBits, 0);
	}
	VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
	                            .memoryTypeIndex = (uint32_t)t };
	VkDeviceMemory m = VK_NULL_HANDLE;
	if (t < 0 || vkAllocateMemory_(dev, &ai, NULL, &m) != VK_SUCCESS) {
		return VK_NULL_HANDLE;
	}
	return m;
}

static VkBuffer
host_buffer(VkDeviceSize size, VkBufferUsageFlags usage, void **map)
{
	VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	VkBuffer b;
	if (vkCreateBuffer_(dev, &bi, NULL, &b) != VK_SUCCESS) {
		return VK_NULL_HANDLE;
	}
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements_(dev, b, &req);
	VkDeviceMemory m = alloc_for(req, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	if (!m || vkBindBufferMemory_(dev, b, m, 0) != VK_SUCCESS || vkMapMemory_(dev, m, 0, VK_WHOLE_SIZE, 0, map) != VK_SUCCESS) {
		return VK_NULL_HANDLE;
	}
	return b;
}

static void
barrier(VkCommandBuffer cb, VkImage img, VkImageLayout from, VkImageLayout to, VkAccessFlags src_a, VkAccessFlags dst_a,
        VkPipelineStageFlags src_s, VkPipelineStageFlags dst_s)
{
	VkImageMemoryBarrier b = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = src_a, .dstAccessMask = dst_a,
	                           .oldLayout = from, .newLayout = to, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	                           .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
	                           .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier_(cb, src_s, dst_s, 0, 0, NULL, 0, NULL, 1, &b);
}

static const uint8_t texels[16] = { 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };

static int
init(char *why, size_t n)
{
	void *lib = dlopen("/private/var/a01/lib/libvulkan_powervr.dylib", RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		snprintf(why, n, "dlopen: %s", dlerror());
		return 0;
	}
	vkGetInstanceProcAddr_ = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");
	if (!vkGetInstanceProcAddr_) {
		snprintf(why, n, "sem vk_icdGetInstanceProcAddr");
		return 0;
	}
	vkCreateInstance_ = (PFN_vkCreateInstance)vkGetInstanceProcAddr_(NULL, "vkCreateInstance");
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	if (!vkCreateInstance_ || vkCreateInstance_(&ici, NULL, &inst) != VK_SUCCESS) {
		snprintf(why, n, "vkCreateInstance");
		return 0;
	}
#define L(x) x##_ = (PFN_##x)vkGetInstanceProcAddr_(inst, #x); if (!x##_) { snprintf(why, n, "sem %s", #x); return 0; }
	L(vkEnumeratePhysicalDevices) L(vkGetPhysicalDeviceMemoryProperties) L(vkCreateDevice) L(vkGetDeviceQueue)
	L(vkCreateBuffer) L(vkGetBufferMemoryRequirements) L(vkAllocateMemory) L(vkBindBufferMemory) L(vkMapMemory)
	L(vkCreateImage) L(vkGetImageMemoryRequirements) L(vkBindImageMemory) L(vkGetImageSubresourceLayout)
	L(vkCreateImageView) L(vkCreateSampler) L(vkCreateDescriptorSetLayout) L(vkCreateDescriptorPool)
	L(vkAllocateDescriptorSets) L(vkUpdateDescriptorSets) L(vkCreatePipelineLayout) L(vkCreateShaderModule)
	L(vkCreateRenderPass) L(vkCreateFramebuffer) L(vkCreateGraphicsPipelines) L(vkCreateCommandPool)
	L(vkAllocateCommandBuffers) L(vkBeginCommandBuffer) L(vkEndCommandBuffer) L(vkCmdPipelineBarrier)
	L(vkCmdCopyBufferToImage) L(vkCmdBeginRenderPass) L(vkCmdEndRenderPass) L(vkCmdBindPipeline)
	L(vkCmdBindDescriptorSets) L(vkCmdDraw) L(vkCmdCopyImageToBuffer) L(vkQueueSubmit) L(vkQueueWaitIdle)
#undef L
	uint32_t cnt = 1;
	if (vkEnumeratePhysicalDevices_(inst, &cnt, &phys) < 0 || cnt == 0) {
		snprintf(why, n, "sem GPU");
		return 0;
	}
	vkGetPhysicalDeviceMemoryProperties_(phys, &memp);
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0,
	                                .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkResult r = vkCreateDevice_(phys, &dci, NULL, &dev);
	if (r != VK_SUCCESS) {
		snprintf(why, n, "vkCreateDevice %d", (int)r);
		return 0;
	}
	vkGetDeviceQueue_(dev, 0, 0, &queue);
	return 1;
}

/* one variant: returns 1 if all four quadrants are right; px gets the four pixels */
static int
run(int linear, int uvmode, uint8_t px[4][4], char *why, size_t n)
{
	/* texture */
	VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
	                         .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { 2, 2, 1 }, .mipLevels = 1, .arrayLayers = 1,
	                         .samples = VK_SAMPLE_COUNT_1_BIT,
	                         .tiling = linear ? VK_IMAGE_TILING_LINEAR : VK_IMAGE_TILING_OPTIMAL,
	                         .usage = VK_IMAGE_USAGE_SAMPLED_BIT | (linear ? 0 : VK_IMAGE_USAGE_TRANSFER_DST_BIT),
	                         .initialLayout = linear ? VK_IMAGE_LAYOUT_PREINITIALIZED : VK_IMAGE_LAYOUT_UNDEFINED };
	VkImage tex;
	if (vkCreateImage_(dev, &ii, NULL, &tex) != VK_SUCCESS) {
		snprintf(why, n, "textura %s nao criada", linear ? "linear" : "otima");
		return 0;
	}
	VkMemoryRequirements req;
	vkGetImageMemoryRequirements_(dev, tex, &req);
	VkDeviceMemory tm = alloc_for(req, linear ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
	                                          : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
	if (!tm || vkBindImageMemory_(dev, tex, tm, 0) != VK_SUCCESS) {
		snprintf(why, n, "memoria da textura");
		return 0;
	}
	if (linear) {
		uint8_t *p;
		if (vkMapMemory_(dev, tm, 0, VK_WHOLE_SIZE, 0, (void **)&p) != VK_SUCCESS) {
			snprintf(why, n, "map da textura linear");
			return 0;
		}
		VkImageSubresource sr = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 };
		VkSubresourceLayout lay;
		vkGetImageSubresourceLayout_(dev, tex, &sr, &lay);
		memcpy(p + lay.offset, texels, 8);
		memcpy(p + lay.offset + lay.rowPitch, texels + 8, 8);
	}
	VkImageViewCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = tex, .viewType = VK_IMAGE_VIEW_TYPE_2D,
	                             .format = VK_FORMAT_R8G8B8A8_UNORM, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView tv;
	VkSamplerCreateInfo si = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_NEAREST,
	                           .minFilter = VK_FILTER_NEAREST, .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
	                           .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
	                           .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, .maxLod = 0.0f };
	VkSampler smp;
	if (vkCreateImageView_(dev, &vi, NULL, &tv) != VK_SUCCESS || vkCreateSampler_(dev, &si, NULL, &smp) != VK_SUCCESS) {
		snprintf(why, n, "view/sampler");
		return 0;
	}

	/* descriptors */
	VkDescriptorSetLayoutBinding lb = { 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL };
	VkDescriptorSetLayoutCreateInfo lci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &lb };
	VkDescriptorSetLayout dsl;
	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1 };
	VkDescriptorPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
	VkDescriptorPool pool;
	VkDescriptorSet set;
	if (vkCreateDescriptorSetLayout_(dev, &lci, NULL, &dsl) != VK_SUCCESS || vkCreateDescriptorPool_(dev, &pci, NULL, &pool) != VK_SUCCESS) {
		snprintf(why, n, "descriptor layout/pool");
		return 0;
	}
	VkDescriptorSetAllocateInfo dai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = pool,
	                                    .descriptorSetCount = 1, .pSetLayouts = &dsl };
	if (vkAllocateDescriptorSets_(dev, &dai, &set) != VK_SUCCESS) {
		snprintf(why, n, "descriptor set");
		return 0;
	}
	VkDescriptorImageInfo dii = { smp, tv, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
	VkWriteDescriptorSet w = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1,
	                           .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &dii };
	vkUpdateDescriptorSets_(dev, 1, &w, 0, NULL);

	/* target 64x64, render pass, pipeline */
	VkImageCreateInfo ti = ii;
	ti.extent = (VkExtent3D){ 64, 64, 1 };
	ti.tiling = VK_IMAGE_TILING_LINEAR;
	ti.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
	ti.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
	VkImage tgt;
	if (vkCreateImage_(dev, &ti, NULL, &tgt) != VK_SUCCESS) {
		snprintf(why, n, "alvo");
		return 0;
	}
	vkGetImageMemoryRequirements_(dev, tgt, &req);
	VkDeviceMemory gm = alloc_for(req, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	if (!gm || vkBindImageMemory_(dev, tgt, gm, 0) != VK_SUCCESS) {
		snprintf(why, n, "memoria do alvo");
		return 0;
	}
	VkImageView gv;
	vi.image = tgt;
	if (vkCreateImageView_(dev, &vi, NULL, &gv) != VK_SUCCESS) {
		snprintf(why, n, "view do alvo");
		return 0;
	}
	VkAttachmentDescription ad = { 0, VK_FORMAT_R8G8B8A8_UNORM, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR,
	                               VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE,
	                               VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL };
	VkAttachmentReference ar = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
	VkSubpassDescription sd = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &ar };
	VkRenderPassCreateInfo rci = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &ad,
	                               .subpassCount = 1, .pSubpasses = &sd };
	VkRenderPass rp;
	VkFramebuffer fb;
	if (vkCreateRenderPass_(dev, &rci, NULL, &rp) != VK_SUCCESS) {
		snprintf(why, n, "render pass");
		return 0;
	}
	VkFramebufferCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp, .attachmentCount = 1,
	                                .pAttachments = &gv, .width = 64, .height = 64, .layers = 1 };
	if (vkCreateFramebuffer_(dev, &fci, NULL, &fb) != VK_SUCCESS) {
		snprintf(why, n, "framebuffer");
		return 0;
	}
	/* uvmode: 0 texture, 1 uv colour, 2 constant smooth, 3 constant flat, 4 gl_FragCoord */
	const unsigned char *vs = uvmode == 2 ? const_vert_spv : uvmode == 3 ? flat_vert_spv : uvmode == 5 ? xonly_vert_spv : uvmode == 6 ? yonly_vert_spv : tex_vert_spv;
	size_t vsz = uvmode == 2 ? sizeof(const_vert_spv) : uvmode == 3 ? sizeof(flat_vert_spv) : uvmode == 5 ? sizeof(xonly_vert_spv) : uvmode == 6 ? sizeof(yonly_vert_spv) : sizeof(tex_vert_spv);
	const unsigned char *fs = uvmode == 0 ? tex_frag_spv : uvmode == 3 ? flat_frag_spv : uvmode == 4 ? fragcoord_frag_spv : uv_frag_spv;
	size_t fsz = uvmode == 0 ? sizeof(tex_frag_spv) : uvmode == 3 ? sizeof(flat_frag_spv)
	           : uvmode == 4 ? sizeof(fragcoord_frag_spv) : sizeof(uv_frag_spv);
	VkShaderModuleCreateInfo mv = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = vsz,
	                                .pCode = (const uint32_t *)vs };
	VkShaderModuleCreateInfo mf = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = fsz,
	                                .pCode = (const uint32_t *)fs };
	VkShaderModule sv, sf;
	VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
	VkPipelineLayout pl;
	if (vkCreateShaderModule_(dev, &mv, NULL, &sv) != VK_SUCCESS || vkCreateShaderModule_(dev, &mf, NULL, &sf) != VK_SUCCESS ||
	    vkCreatePipelineLayout_(dev, &plci, NULL, &pl) != VK_SUCCESS) {
		snprintf(why, n, "shaders/layout");
		return 0;
	}
	VkPipelineShaderStageCreateInfo st[2] = {
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = sv, .pName = "main" },
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = sf, .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vis = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ias = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
	                                               .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkViewport vp = { 0, 0, 64, 64, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { 64, 64 } };
	VkPipelineViewportStateCreateInfo vps = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1,
	                                          .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
	                                              .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1.0f };
	VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
	                                            .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cbs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1,
	                                            .pAttachments = &cba };
	VkGraphicsPipelineCreateInfo gpi = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = st,
	                                     .pVertexInputState = &vis, .pInputAssemblyState = &ias, .pViewportState = &vps,
	                                     .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cbs,
	                                     .layout = pl, .renderPass = rp };
	VkPipeline pipe;
	if (vkCreateGraphicsPipelines_(dev, VK_NULL_HANDLE, 1, &gpi, NULL, &pipe) != VK_SUCCESS) {
		snprintf(why, n, "pipeline");
		return 0;
	}

	/* buffers: staging (V1) and readback */
	void *stage_p, *out_p;
	VkBuffer stage = host_buffer(16, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &stage_p);
	VkBuffer out = host_buffer(64 * 64 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &out_p);
	if (!stage || !out) {
		snprintf(why, n, "buffers");
		return 0;
	}
	memcpy(stage_p, texels, 16);
	memset(out_p, 0x55, 64 * 64 * 4);

	/* record */
	VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
	VkCommandPool cp;
	VkCommandBuffer cb;
	VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
	                                    .commandBufferCount = 1 };
	if (vkCreateCommandPool_(dev, &cpi, NULL, &cp) != VK_SUCCESS) {
		snprintf(why, n, "command pool");
		return 0;
	}
	cai.commandPool = cp;
	VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	if (vkAllocateCommandBuffers_(dev, &cai, &cb) != VK_SUCCESS || vkBeginCommandBuffer_(cb, &bi) != VK_SUCCESS) {
		snprintf(why, n, "command buffer");
		return 0;
	}
	if (linear) {
		barrier(cb, tex, VK_IMAGE_LAYOUT_PREINITIALIZED, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_ACCESS_HOST_WRITE_BIT,
		        VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
	} else {
		barrier(cb, tex, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
		        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		VkBufferImageCopy bc = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { 2, 2, 1 } };
		vkCmdCopyBufferToImage_(cb, stage, tex, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bc);
		barrier(cb, tex, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT,
		        VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
	}
	VkClearValue cv = { .color = { .float32 = { 0, 0, 0, 1 } } };
	VkRenderPassBeginInfo rbi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp, .framebuffer = fb,
	                              .renderArea = sc, .clearValueCount = 1, .pClearValues = &cv };
	vkCmdBeginRenderPass_(cb, &rbi, VK_SUBPASS_CONTENTS_INLINE);
	vkCmdBindPipeline_(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
	vkCmdBindDescriptorSets_(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pl, 0, 1, &set, 0, NULL);
	vkCmdDraw_(cb, 3, 1, 0, 0);
	vkCmdEndRenderPass_(cb);
	VkBufferImageCopy rc = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { 64, 64, 1 } };
	vkCmdCopyImageToBuffer_(cb, tgt, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, out, 1, &rc);
	if (vkEndCommandBuffer_(cb) != VK_SUCCESS) {
		snprintf(why, n, "vkEndCommandBuffer");
		return 0;
	}
	VkSubmitInfo sub = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
	VkResult r = vkQueueSubmit_(queue, 1, &sub, VK_NULL_HANDLE);
	if (r != VK_SUCCESS) {
		snprintf(why, n, "vkQueueSubmit %d", (int)r);
		return 0;
	}
	vkQueueWaitIdle_(queue);
	usleep(300000);   /* the fences cap at 2 s; give the copy time to land as A01Metal does */

	/* inside 16x16 tiles (tile-local 8): tile corners hid per-tile constant interpolation */
	static const int at[4][2] = { { 24, 24 }, { 40, 24 }, { 24, 40 }, { 40, 40 } };
	uint8_t *direct = NULL;
	VkImageSubresource tsr = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 };
	VkSubresourceLayout tlay;
	vkGetImageSubresourceLayout_(dev, tgt, &tsr, &tlay);
	if (vkMapMemory_(dev, gm, 0, VK_WHOLE_SIZE, 0, (void **)&direct) != VK_SUCCESS) {
		direct = NULL;
	}
	/* the copy's first pixel, to compare with the direct read */
	memcpy(g_vt_copy0, (uint8_t *)out_p + 4 * (at[0][1] * 64 + at[0][0]), 4);
	int ok = 1;
	for (int i = 0; i < 4; i++) {
		if (direct) {
			memcpy(px[i], direct + tlay.offset + (size_t)at[i][1] * tlay.rowPitch + 4u * (unsigned)at[i][0], 4);
		} else {
			memcpy(px[i], (uint8_t *)out_p + 4 * (at[i][1] * 64 + at[i][0]), 4);
		}
		if (uvmode == 2 || uvmode == 3) {
			/* (0.5, 0.25) -> 0x80 0x40 */
			ok &= abs(px[i][0] - 128) <= 3 && abs(px[i][1] - 64) <= 3 && px[i][2] == 0 && px[i][3] == 255;
		} else if (uvmode) {
			/* halved: pixel centre / 128: (16.5/128)*255 = 33 (0x21), (48.5/128)*255 = 97 (0x61) */
			/* pixel centre / 128: (24.5/128)*255 = 49 (0x31), (40.5/128)*255 = 81 (0x51) */
			int ex = at[i][0] > 32 ? 81 : 49, ey = at[i][1] > 32 ? 81 : 49;
			if (uvmode == 5) ey = 0;
			if (uvmode == 6) ex = 0;
			ok &= abs(px[i][0] - ex) <= 3 && abs(px[i][1] - ey) <= 3 && px[i][2] == 0 && px[i][3] == 255;
		} else {
			ok &= memcmp(px[i], texels + 4 * i, 4) == 0;
		}
	}
	return ok;
}

/* one "A01 >>> Vn ..." line per variant through emit() as soon as it is done (a hang or crash in a later
 * variant keeps the earlier lines); step(v) before each so the watchdog names the variant */
void
a01_vk_tex_test(void (*emit)(const char *), void (*step)(int), char marks[9])
{
	char out[300];
	size_t n = sizeof(out);
	char why[96] = "";
	memset(marks, '-', 9);
	if (!init(why, sizeof(why))) {
		snprintf(out, n, "A01 >>> VT: Vulkan nao iniciou (%s) <<<\n", why);
		emit(out);
		return;
	}
	for (int v = 0; v < 9; v++) {
		uint8_t px[4][4];
		memset(px, 0, sizeof(px));
		why[0] = '\0';
		step(v);
		if (v == 8) setenv("A01_PVR_ITER_ZERO", "1", 1);
		int ok = run(v == 1, v == 8 ? 1 : v >= 2 ? v - 1 : 0, px, why, sizeof(why));
		if (v == 8) unsetenv("A01_PVR_ITER_ZERO");
		marks[v] = ok ? '+' : '-';
		snprintf(out, n,
		                 "A01 >>> V%d (%s): %s %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x%s%s <<<\n", v + 1,
		                 v == 5 ? "posicao (21 21 / 61 61)" : v == 4 ? "constante flat (80 40)" : v == 3 ? "constante (80 40)"
		                 : v == 2 ? "coordenada (21 21 / 61 61)" : v ? "linear CPU" : "copia GPU", ok ? "OK" : "ERRO", px[0][0], px[0][1], px[0][2], px[0][3], px[1][0],
		                 px[1][1], px[1][2], px[1][3], px[2][0], px[2][1], px[2][2], px[2][3], px[3][0], px[3][1], px[3][2],
		                 px[3][3], why[0] ? " falhou: " : "", why);
		{
			/* append the GPU copy's first pixel: " c xxxxxxxx" (before the closing marker) */
			char *end = strstr(out, " <<<");
			if (end) {
				snprintf(end, n - (size_t)(end - out), " c %02x%02x%02x%02x <<<\n", g_vt_copy0[0], g_vt_copy0[1],
				         g_vt_copy0[2], g_vt_copy0[3]);
			}
		}
		emit(out);
	}
}
