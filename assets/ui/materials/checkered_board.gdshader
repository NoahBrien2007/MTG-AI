shader_type spatial;
render_mode depth_draw_always, cull_disabled;

uniform vec4 fill_color : source_color = vec4(0.0, 0.75, 1.0, 0.12);
uniform vec4 grid_line_color : source_color = vec4(0.0, 0.85, 1.0, 0.45);
uniform vec4 outline_color : source_color = vec4(0.0, 0.9, 1.0, 0.70);

// Board size in world units (match your QuadMesh size)
uniform vec2 board_dimensions = vec2(12.0, 4.5);

// MTG card size in world units (real ratio: 63mm x 88mm = 1 : 1.397)
// Adjust scale to make slots bigger or smaller, ratio stays locked
uniform float card_scale = 1.0;
const vec2 MTG_RATIO = vec2(1.0, 1.4);

uniform float grid_line_thickness : hint_range(0.0005, 0.05) = 0.012;
uniform float outline_thickness : hint_range(0.0005, 0.1) = 0.008;

uniform float hover_alpha : hint_range(0.0, 1.0) = 0.0;


void fragment() {
	vec2 uv = UV;

	vec2 card_world_size = MTG_RATIO * card_scale;

	// Cell UV size preserves real-world aspect ratio
	vec2 cell_uv = card_world_size / board_dimensions;

	// Outer border
	vec2 outer_border = step(vec2(outline_thickness), uv) * step(vec2(outline_thickness), 1.0 - uv);
	float is_outer_border = 1.0 - (outer_border.x * outer_border.y);

	// Inner grid lines at world-correct MTG card boundaries
	vec2 grid_uv = fract(uv / cell_uv);
	vec2 grid_edge = step(vec2(grid_line_thickness), grid_uv) * step(vec2(grid_line_thickness), 1.0 - grid_uv);
	float is_grid_line = 1.0 - (grid_edge.x * grid_edge.y);

	vec4 final_color = fill_color;

	if (is_grid_line > 0.5) {
		final_color = grid_line_color;
	}

	if (is_outer_border > 0.5) {
		final_color = outline_color;
	}

	ALBEDO = final_color.rgb;
	ALPHA = final_color.a * hover_alpha;
	ROUGHNESS = 0.2;
}
