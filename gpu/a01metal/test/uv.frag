#version 450
// a01vktex V3: the interpolated coordinate itself as the colour (no texture), to see the iterators.
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
void main()
{
	color = vec4(uv * 0.5, 0.0, 1.0);   /* halved: values up to 1.0 stay readable */
}
