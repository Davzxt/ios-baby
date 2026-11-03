#version 450
// a01vktex: the 2x2 texture, NEAREST.
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
void main()
{
	color = texture(tex, uv);
}
