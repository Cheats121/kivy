import ctypes

include "../../../kivy/lib/sdl2.pxi"
include "../../include/config.pxi"

from libc.string cimport memcpy
from os import environ
from kivy.config import Config
from kivy.logger import Logger
from kivy import platform
from kivy.graphics.cgl cimport *

from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free

if not environ.get('KIVY_DOC_INCLUDE'):
    is_desktop = Config.get('kivy', 'desktop') == '1'

IF USE_WAYLAND:
    from .window_info cimport WindowInfoWayland

IF USE_X11:
    from .window_info cimport WindowInfoX11

IF UNAME_SYSNAME == 'Windows':
    from .window_info cimport WindowInfoWindows


cdef int _event_filter(void *userdata, SDL_Event *event) noexcept with gil:
    return (<_WindowSDL2Storage>userdata).cb_event_filter(event)


cdef class _WindowSDL2Storage:
    cdef SDL_Window *win
    cdef SDL_GLContext ctx
    cdef SDL_Surface *surface
    cdef SDL_Surface *icon
    cdef int win_flags
    cdef object event_filter

    def __cinit__(self):
        self.win = NULL
        self.ctx = NULL
        self.surface = NULL
        self.win_flags = 0
        self.event_filter = None

    def set_event_filter(self, event_filter):
        self.event_filter = event_filter

    cdef int cb_event_filter(self, SDL_Event *event):
        cdef str name = None
        if not self.event_filter:
            return 1
        if event.type == SDL_WINDOWEVENT:
            if is_desktop and event.window.event == SDL_WINDOWEVENT_RESIZED:
                action = ('windowresized',
                          event.window.data1, event.window.data2)
                return self.event_filter(*action)
        elif event.type == SDL_APP_TERMINATING:
            name = 'app_terminating'
        elif event.type == SDL_APP_LOWMEMORY:
            name = 'app_lowmemory'
        elif event.type == SDL_APP_WILLENTERBACKGROUND:
            name = 'app_willenterbackground'
        elif event.type == SDL_APP_DIDENTERBACKGROUND:
            name = 'app_didenterbackground'
        elif event.type == SDL_APP_WILLENTERFOREGROUND:
            name = 'app_willenterforeground'
        elif event.type == SDL_APP_DIDENTERFOREGROUND:
            name = 'app_didenterforeground'
        if not name:
            return 1
        return self.event_filter(name)

    def die(self):
        raise RuntimeError(<bytes> SDL_GetError())

    def setup_window(self, x, y, width, height, borderless, fullscreen, resizable, state, gl_backend):
        self.win_flags = SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI

        if resizable:
            self.win_flags |= SDL_WINDOW_RESIZABLE

        if not USE_IOS:
            if borderless:
                self.win_flags |= SDL_WINDOW_BORDERLESS

        if USE_ANDROID:
            if environ.get('P4A_IS_WINDOWED', 'True') == 'False':
                self.win_flags |= SDL_WINDOW_FULLSCREEN
        elif USE_IOS:
            if environ.get('IOS_IS_WINDOWED', 'True') == 'False':
                self.win_flags |= SDL_WINDOW_FULLSCREEN | SDL_WINDOW_BORDERLESS
        elif fullscreen == 'auto':
            self.win_flags |= SDL_WINDOW_FULLSCREEN_DESKTOP
        elif fullscreen is True:
            self.win_flags |= SDL_WINDOW_FULLSCREEN
        if state == 'maximized':
            self.win_flags |= SDL_WINDOW_MAXIMIZED
        elif state == 'minimized':
            self.win_flags |= SDL_WINDOW_MINIMIZED
        elif state == 'hidden':
            self.win_flags |= SDL_WINDOW_HIDDEN

        show_taskbar_icon = Config.getboolean('graphics', 'show_taskbar_icon')
        if not show_taskbar_icon:
            self.win_flags |= SDL_WINDOW_SKIP_TASKBAR

        SDL_SetHint(SDL_HINT_ACCELEROMETER_AS_JOYSTICK, b'0')
        SDL_SetHintWithPriority(b'SDL_ANDROID_TRAP_BACK_BUTTON', b'1', SDL_HINT_OVERRIDE)
        
        if platform == "win":
            SDL_SetHint(SDL_HINT_WINDOWS_DPI_SCALING, b"1")

        if SDL_Init(SDL_INIT_VIDEO | SDL_INIT_JOYSTICK) < 0:
            self.die()

        orientations = 'LandscapeLeft LandscapeRight'
        if USE_IOS:
            orientations = 'LandscapeLeft LandscapeRight Portrait PortraitUpsideDown'
        if USE_ANDROID:
            orientations = ''
        orientations = environ.get('KIVY_ORIENTATION', orientations)
        SDL_SetHint(SDL_HINT_ORIENTATIONS, <bytes>(orientations.encode('utf-8')))

        SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)
        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 16)
        SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8)
        SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8)
        SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8)
        SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8)
        SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, KIVY_SDL_GL_ALPHA_SIZE)
        SDL_GL_SetAttribute(SDL_GL_RETAINED_BACKING, 0)
        SDL_GL_SetAttribute(SDL_GL_ACCELERATED_VISUAL, 1)

        if gl_backend == "angle_sdl2":
            Logger.info("Window: Activate GLES2/ANGLE context")
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, 4)
            SDL_SetHint(SDL_HINT_VIDEO_WIN_D3DCOMPILER, "none")

        if x is None:
            x = SDL_WINDOWPOS_UNDEFINED
        if y is None:
            y = SDL_WINDOWPOS_UNDEFINED

        cdef int multisamples, shaped
        multisamples = Config.getint('graphics', 'multisamples')
        shaped = Config.getint('graphics', 'shaped')

        if multisamples > 0 and shaped > 0:
            SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1)
            SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, min(multisamples, 4))
            self.win = SDL_CreateShapedWindow(NULL, x, y, width, height, self.win_flags)
            if not self.win:
                SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 0)
                SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, 0)
                self.win = SDL_CreateShapedWindow(NULL, x, y, width, height, self.win_flags)
            if not self.win:
                self.win = SDL_CreateWindow(NULL, x, y, width, height, self.win_flags)
        elif multisamples > 0:
            SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1)
            SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, min(multisamples, 4))
            self.win = SDL_CreateWindow(NULL, x, y, width, height, self.win_flags)
            if not self.win:
                SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 0)
                SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, 0)
                self.win = SDL_CreateWindow(NULL, x, y, width, height, self.win_flags)
        elif shaped > 0:
            self.win = SDL_CreateShapedWindow(NULL, x, y, width, height, self.win_flags)
            if not self.win:
                self.win = SDL_CreateWindow(NULL, x, y, width, height, self.win_flags)
        else:
            self.win = SDL_CreateWindow(NULL, x, y, width, height, self.win_flags)

        if shaped > 0 and self.is_window_shaped():
            self.set_window_pos(100, 100)

        if not self.win:
            self.die()

        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2)
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0)

        if gl_backend != "mock":
            self.ctx = SDL_GL_CreateContext(self.win)
            if not self.ctx:
                self.die()

        vsync = Config.get('graphics', 'vsync')
        if vsync and vsync != 'none':
            vsync = Config.getint('graphics', 'vsync')
            Logger.debug(f'WindowSDL: setting vsync interval=={vsync}')
            res = SDL_GL_SetSwapInterval(vsync)
            if res == -1:
                status = ''
                if vsync not in (0, 1):
                    res = SDL_GL_SetSwapInterval(1)
                    status = ', trying fallback to 1: ' + ('failed' if res == -1 else 'succeeded')
                Logger.debug('WindowSDL: requested vsync failed' + status)

        cdef int joy_i
        for joy_i in range(SDL_NumJoysticks()):
            SDL_JoystickOpen(joy_i)

        SDL_SetEventFilter(_event_filter, <void *>self)

        SDL_EventState(SDL_DROPFILE, SDL_ENABLE)
        SDL_EventState(SDL_DROPTEXT, SDL_ENABLE)
        SDL_EventState(SDL_DROPBEGIN, SDL_ENABLE)
        SDL_EventState(SDL_DROPCOMPLETE, SDL_ENABLE)
        cdef int w, h
        SDL_GetWindowSize(self.win, &w, &h)
        return w, h

    # ... (rest of methods unchanged until custom_titlebar_handler_callback)

    def set_custom_titlebar(self, titlebar_widget):
        SDL_SetWindowBordered(self.win, SDL_FALSE)
        return SDL_SetWindowHitTest(self.win, custom_titlebar_handler_callback, <void *>titlebar_widget)

    @property
    def window_size(self):
        cdef int w, h
        SDL_GetWindowSize(self.win, &w, &h)
        return [w, h]


cdef SDL_HitTestResult custom_titlebar_handler_callback(
    SDL_Window* win, const SDL_Point* pts, void* data
) noexcept with gil:

    cdef int border = max(
        Config.getdefaultint('graphics','custom_titlebar_border',5),
        Config.getint('graphics', 'custom_titlebar_border')
    )
    cdef int w, h
    SDL_GetWindowSize(<SDL_Window *> win, &w, &h)

    if Config.getboolean('graphics', 'resizable'):
        if pts.x < border and pts.y < border:
            return SDL_HITTEST_RESIZE_TOPLEFT
        elif pts.x < border < h - pts.y:
            return SDL_HITTEST_RESIZE_LEFT
        elif pts.x < border and h - pts.y < border:
            return SDL_HITTEST_RESIZE_BOTTOMLEFT
        elif w - pts.x < border > pts.y:
            return SDL_HITTEST_RESIZE_TOPRIGHT
        elif w - pts.x  > border > pts.y:
            return SDL_HITTEST_RESIZE_TOP
        elif w - pts.x  < border < h - pts.y:
            return SDL_HITTEST_RESIZE_RIGHT
        elif w - pts.x  < border > h - pts.y:
            return SDL_HITTEST_RESIZE_BOTTOMRIGHT
        elif w - pts.x  > border > h - pts.y:
            return SDL_HITTEST_RESIZE_BOTTOM

    widget = <object> data
    if widget.collide_point(pts.x, h - pts.y):
        in_drag_area = getattr(widget, 'in_drag_area', None)
        if callable(in_drag_area):
            if in_drag_area(pts.x, h - pts.y):
                return SDL_HITTEST_DRAGGABLE
            else:
                return SDL_HITTEST_NORMAL
        for child in widget.walk():
            drag = getattr(child, 'draggable', None)
            if drag is not None and not drag and child.collide_point(pts.x, h - pts.y):
                return SDL_HITTEST_NORMAL
        return SDL_HITTEST_DRAGGABLE

    return SDL_HITTEST_NORMAL


cdef SDL_Surface* flipVert(SDL_Surface* sfc):
    cdef SDL_Surface* result = SDL_CreateRGBSurface(
        sfc.flags, sfc.w, sfc.h, sfc.format.BytesPerPixel * 8,
        sfc.format.Rmask, sfc.format.Gmask, sfc.format.Bmask,
        sfc.format.Amask
    )

    cdef Uint8* pixels = <Uint8*>sfc.pixels
    cdef Uint8* rpixels = <Uint8*>result.pixels

    cdef tuple output = (
        <int>sfc.w, <int>sfc.h,
        <int>sfc.format.BytesPerPixel,
        <int>sfc.pitch
    )
    Logger.debug(f"Window: Screenshot output dimensions {output}")

    cdef Uint32 pitch = sfc.pitch
    cdef Uint32 pxlength = pitch * sfc.h
    cdef Uint32 pos

    cdef int line
    for line in range(sfc.h):
        pos = line * pitch
        memcpy(&rpixels[pos], &pixels[(pxlength - pos) - pitch], pitch)

    return result
