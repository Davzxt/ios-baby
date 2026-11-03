#version 450
// a01vktex V5: flat input as the colour.
layout(location = 0) flat in vec2 uv;
layout(location = 0) out vec4 color;
void main()
{
	color = vec4(uv, 0.0, 1.0);
}
