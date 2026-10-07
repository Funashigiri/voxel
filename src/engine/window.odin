package engine

// Окно, OpenGL-контекст и ввод (клавиатура / мышь) поверх GLFW.

import "core:c"
import "core:fmt"
import "core:strings"
import gl "vendor:OpenGL"
import "vendor:glfw"

GL_MAJOR :: 3
GL_MINOR :: 3

KEY_COUNT :: glfw.KEY_LAST + 1
BUTTON_COUNT :: glfw.MOUSE_BUTTON_LAST + 1

Window :: struct {
	handle:          glfw.WindowHandle,
	fb_width:        i32,
	fb_height:       i32,
	keys:            [KEY_COUNT]bool, // клавиша зажата
	keys_hit:        [KEY_COUNT]bool, // нажата в этом кадре
	buttons:         [BUTTON_COUNT]bool,
	buttons_hit:     [BUTTON_COUNT]bool,
	mouse_dx:        f32,
	mouse_dy:        f32,
	scroll:          f32,
	scroll_accum:    f32,
	last_mouse:      [2]f64,
	have_last_mouse: bool,
	cursor_locked:   bool,
	focused:         bool,
}

win: Window

@(private)
key_callback :: proc "c" (handle: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	if key < 0 || key >= KEY_COUNT do return
	switch action {
	case glfw.PRESS:
		win.keys[key] = true
		win.keys_hit[key] = true
	case glfw.RELEASE:
		win.keys[key] = false
	}
}

@(private)
mouse_button_callback :: proc "c" (handle: glfw.WindowHandle, button, action, mods: c.int) {
	if button < 0 || button >= BUTTON_COUNT do return
	switch action {
	case glfw.PRESS:
		win.buttons[button] = true
		win.buttons_hit[button] = true
	case glfw.RELEASE:
		win.buttons[button] = false
	}
}

@(private)
scroll_callback :: proc "c" (handle: glfw.WindowHandle, xoffset, yoffset: f64) {
	win.scroll_accum += f32(yoffset)
}

@(private)
focus_callback :: proc "c" (handle: glfw.WindowHandle, focused: c.int) {
	win.focused = focused != 0
	if !win.focused {
		win.keys = {}
		win.buttons = {}
	}
}

window_create :: proc(title: string, width, height: i32) -> bool {
	if !glfw.Init() {
		fmt.eprintln("[engine] glfw.Init failed")
		return false
	}
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_MAJOR)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_MINOR)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1)

	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	win.handle = glfw.CreateWindow(width, height, ctitle, nil, nil)
	if win.handle == nil {
		fmt.eprintln("[engine] glfw.CreateWindow failed (нужен OpenGL 3.3)")
		glfw.Terminate()
		return false
	}
	glfw.MakeContextCurrent(win.handle)
	glfw.SwapInterval(1)
	gl.load_up_to(GL_MAJOR, GL_MINOR, glfw.gl_set_proc_address)

	glfw.SetKeyCallback(win.handle, key_callback)
	glfw.SetMouseButtonCallback(win.handle, mouse_button_callback)
	glfw.SetScrollCallback(win.handle, scroll_callback)
	glfw.SetWindowFocusCallback(win.handle, focus_callback)
	if glfw.RawMouseMotionSupported() {
		glfw.SetInputMode(win.handle, glfw.RAW_MOUSE_MOTION, 1)
	}

	win.fb_width, win.fb_height = glfw.GetFramebufferSize(win.handle)
	win.focused = true
	return true
}

window_destroy :: proc() {
	glfw.DestroyWindow(win.handle)
	glfw.Terminate()
}

window_should_close :: proc() -> bool {
	return bool(glfw.WindowShouldClose(win.handle))
}

window_request_close :: proc() {
	glfw.SetWindowShouldClose(win.handle, true)
}

// Вызывается в начале кадра: опрос событий и вычисление смещения мыши.
window_begin_frame :: proc() {
	win.keys_hit = {}
	win.buttons_hit = {}
	win.scroll_accum = 0
	glfw.PollEvents()
	win.scroll = win.scroll_accum
	win.fb_width, win.fb_height = glfw.GetFramebufferSize(win.handle)

	mx, my := glfw.GetCursorPos(win.handle)
	win.mouse_dx, win.mouse_dy = 0, 0
	if win.cursor_locked && win.have_last_mouse {
		win.mouse_dx = f32(mx - win.last_mouse.x)
		win.mouse_dy = f32(my - win.last_mouse.y)
	}
	win.last_mouse = {mx, my}
	win.have_last_mouse = true
}

window_end_frame :: proc() {
	glfw.SwapBuffers(win.handle)
}

window_set_title :: proc(title: string) {
	glfw.SetWindowTitle(win.handle, strings.clone_to_cstring(title, context.temp_allocator))
}

set_cursor_locked :: proc(locked: bool) {
	win.cursor_locked = locked
	glfw.SetInputMode(win.handle, glfw.CURSOR, locked ? glfw.CURSOR_DISABLED : glfw.CURSOR_NORMAL)
	win.have_last_mouse = false
}

key_down :: proc(key: c.int) -> bool {return win.keys[key]}
key_pressed :: proc(key: c.int) -> bool {return win.keys_hit[key]}
mouse_down :: proc(button: c.int) -> bool {return win.buttons[button]}
mouse_pressed :: proc(button: c.int) -> bool {return win.buttons_hit[button]}

time_now :: proc() -> f64 {
	return glfw.GetTime()
}
