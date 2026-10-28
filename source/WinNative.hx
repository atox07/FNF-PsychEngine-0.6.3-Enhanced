package;

#if windows
/**
 * Livello nativo (WinAPI) per le finestre extra.
 *
 * Non usa Lime/OpenFL per creare le finestre: crea finestre Win32 "pure"
 * che il thread principale (SDL) gia' smista con la sua message pump.
 *  - finestra normale  -> si disegna con StretchDIBits (opaca, con titolo/bordo)
 *  - finestra layered  -> si disegna con UpdateLayeredWindow (trasparenza PER PIXEL,
 *                         niente aloni, sembra che lo sprite sia sul desktop)
 *
 * Tutte le finestre sono WS_EX_NOACTIVATE: non rubano il focus al gioco.
 * Le coordinate x,y sono sempre quelle dell'AREA CLIENT sullo schermo.
 */
@:buildXml('
<target id="haxe">
	<lib name="user32.lib" if="windows" />
	<lib name="gdi32.lib" if="windows" />
</target>
')
@:cppFileCode('
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <stdint.h>

// WndProc delle finestre extra: non catturano MAI il mouse e non avviano
// il loop modale di trascinamento/ridimensionamento (che bloccherebbe il gioco
// e il cursore finche\' tieni premuto).
static LRESULT CALLBACK PsychExtraProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
	switch (m)
	{
		case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
		case WM_SYSCOMMAND:
		{
			UINT c = (UINT)(w & 0xFFF0);
			if (c == SC_MOVE || c == SC_SIZE || c == SC_KEYMENU) return 0;
			break;
		}
		case WM_CAPTURECHANGED: break;
	}
	return DefWindowProcW(h, m, w, l);
}

// Cache dei buffer DIB per finestra: niente CreateDIBSection/DeleteObject a ogni frame.
struct PsychBuf { HWND hwnd; int w; int h; HBITMAP bmp; void* bits; HDC dc; HGDIOBJ old; };
static PsychBuf g_pb[32];
static HDC g_screenDC = NULL;

static void PsychFreeBuf(PsychBuf* b)
{
	if (b->dc) { if (b->old) SelectObject(b->dc, b->old); DeleteDC(b->dc); }
	if (b->bmp) DeleteObject(b->bmp);
	ZeroMemory(b, sizeof(PsychBuf));
}

static void PsychFreeBufFor(HWND hwnd)
{
	for (int i = 0; i < 32; i++) if (g_pb[i].hwnd == hwnd) PsychFreeBuf(&g_pb[i]);
}

static PsychBuf* PsychGetBuf(HWND hwnd, int w, int h, BITMAPINFO* bi)
{
	PsychBuf* slot = NULL;
	for (int i = 0; i < 32; i++)
	{
		if (g_pb[i].hwnd == hwnd)
		{
			if (g_pb[i].w == w && g_pb[i].h == h && g_pb[i].bmp) return &g_pb[i];
			PsychFreeBuf(&g_pb[i]);
			slot = &g_pb[i];
			break;
		}
		if (g_pb[i].hwnd == NULL && slot == NULL) slot = &g_pb[i];
	}
	if (slot == NULL) return NULL;
	if (g_screenDC == NULL) g_screenDC = GetDC(NULL);
	void* bits = NULL;
	HBITMAP bmp = CreateDIBSection(g_screenDC, bi, DIB_RGB_COLORS, &bits, NULL, 0);
	if (bmp == NULL || bits == NULL) { if (bmp) DeleteObject(bmp); return NULL; }
	HDC dc = CreateCompatibleDC(g_screenDC);
	HGDIOBJ old = SelectObject(dc, bmp);
	slot->hwnd = hwnd; slot->w = w; slot->h = h; slot->bmp = bmp; slot->bits = bits; slot->dc = dc; slot->old = old;
	return slot;
}
')
class WinNative
{
	@:functionCode('
		static bool registered = false;
		HINSTANCE inst = GetModuleHandleW(NULL);
		if (!registered)
		{
			WNDCLASSEXW wc;
			ZeroMemory(&wc, sizeof(wc));
			wc.cbSize = sizeof(WNDCLASSEXW);
			wc.lpfnWndProc = PsychExtraProc;
			wc.hInstance = inst;
			wc.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512));
			wc.lpszClassName = L"PsychLuaExtraWindow";
			RegisterClassExW(&wc);
			registered = true;
		}

		bool noFrame = borderless || layered;
		DWORD style = noFrame ? WS_POPUP : (WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX);
		DWORD ex = WS_EX_NOACTIVATE;
		if (noFrame) ex |= WS_EX_TOOLWINDOW;
		if (topmost) ex |= WS_EX_TOPMOST;
		if (layered) ex |= WS_EX_LAYERED | WS_EX_TRANSPARENT; // click-through di default

		RECT rc;
		rc.left = x; rc.top = y; rc.right = x + w; rc.bottom = y + hgt;
		AdjustWindowRectEx(&rc, style, FALSE, ex);

		HWND hwnd = CreateWindowExW(ex, L"PsychLuaExtraWindow", title.wchar_str(), style,
			rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top,
			NULL, NULL, inst, NULL);
		if (hwnd == NULL) return 0;
		ShowWindow(hwnd, SW_SHOWNOACTIVATE);
		return (int)(intptr_t)hwnd;
	')
	public static function createWin(title:String, x:Int, y:Int, w:Int, hgt:Int, borderless:Bool, topmost:Bool, layered:Bool):Int
	{
		return 0;
	}

	@:functionCode('
		PsychFreeBufFor((HWND)(intptr_t)hnd);
		DestroyWindow((HWND)(intptr_t)hnd);
	')
	public static function destroyWin(hnd:Int):Void {}

	@:functionCode('
		return IsWindow((HWND)(intptr_t)hnd) != 0;
	')
	public static function isAlive(hnd:Int):Bool
	{
		return false;
	}

	@:functionCode('
		HWND hwnd = (HWND)(intptr_t)hnd;
		RECT wr; GetWindowRect(hwnd, &wr);
		POINT p; p.x = 0; p.y = 0;
		ClientToScreen(hwnd, &p);
		int offX = p.x - wr.left;
		int offY = p.y - wr.top;
		SetWindowPos(hwnd, NULL, x - offX, y - offY, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
	')
	public static function setPos(hnd:Int, x:Int, y:Int):Void {}

	@:functionCode('
		HWND hwnd = (HWND)(intptr_t)hnd;
		POINT p; p.x = 0; p.y = 0;
		ClientToScreen(hwnd, &p);
		return (int)p.x;
	')
	public static function getPosX(hnd:Int):Int
	{
		return 0;
	}

	@:functionCode('
		HWND hwnd = (HWND)(intptr_t)hnd;
		POINT p; p.x = 0; p.y = 0;
		ClientToScreen(hwnd, &p);
		return (int)p.y;
	')
	public static function getPosY(hnd:Int):Int
	{
		return 0;
	}

	@:functionCode('
		HWND hwnd = (HWND)(intptr_t)hnd;
		DWORD style = (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE);
		DWORD ex = (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
		RECT rc; rc.left = 0; rc.top = 0; rc.right = w; rc.bottom = hgt;
		AdjustWindowRectEx(&rc, style, FALSE, ex);
		SetWindowPos(hwnd, NULL, 0, 0, rc.right - rc.left, rc.bottom - rc.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
	')
	public static function setSize(hnd:Int, w:Int, hgt:Int):Void {}

	@:functionCode('
		SetWindowTextW((HWND)(intptr_t)hnd, title.wchar_str());
	')
	public static function setTitle(hnd:Int, title:String):Void {}

	@:functionCode('
		SetWindowPos((HWND)(intptr_t)hnd, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
	')
	public static function setTopmost(hnd:Int, on:Bool):Void {}

	@:functionCode('
		HWND hwnd = (HWND)(intptr_t)hnd;
		POINT p; p.x = 0; p.y = 0;
		ClientToScreen(hwnd, &p);
		RECT cr; GetClientRect(hwnd, &cr);
		int cw = cr.right;
		int ch = cr.bottom;

		DWORD style = (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE);
		style &= ~(WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_POPUP);
		if (on) style |= WS_POPUP; else style |= (WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX);
		SetWindowLongPtrW(hwnd, GWL_STYLE, (LONG_PTR)style);

		DWORD ex = (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
		RECT rc; rc.left = p.x; rc.top = p.y; rc.right = p.x + cw; rc.bottom = p.y + ch;
		AdjustWindowRectEx(&rc, style, FALSE, ex);
		SetWindowPos(hwnd, NULL, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top, SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOACTIVATE);
	')
	public static function setBorderless(hnd:Int, on:Bool):Void {}

	@:functionCode('
		HWND hwnd = (HWND)(intptr_t)hnd;
		DWORD ex = (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
		if (on) ex |= WS_EX_LAYERED; else ex &= ~WS_EX_LAYERED;
		SetWindowLongPtrW(hwnd, GWL_EXSTYLE, (LONG_PTR)ex);
		SetWindowPos(hwnd, NULL, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
	')
	public static function setLayered(hnd:Int, on:Bool):Void {}

	@:functionCode('
		HWND hwnd = (HWND)(intptr_t)hnd;
		DWORD ex = (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
		if (on) ex |= WS_EX_TRANSPARENT; else ex &= ~WS_EX_TRANSPARENT;
		SetWindowLongPtrW(hwnd, GWL_EXSTYLE, (LONG_PTR)ex);
	')
	public static function setClickThrough(hnd:Int, on:Bool):Void {}

	@:functionCode('
		return (int)GetSystemMetrics(SM_CXSCREEN);
	')
	public static function screenWidth():Int
	{
		return 0;
	}

	@:functionCode('
		return (int)GetSystemMetrics(SM_CYSCREEN);
	')
	public static function screenHeight():Int
	{
		return 0;
	}

	/**
	 * Sposta/ridimensiona la finestra VERA del gioco con UNA sola chiamata
	 * (invece dei 4 set separati di Lime). x,y,w,h sono in coordinate dell'AREA CLIENT,
	 * le stesse di application.window.x/y/width/height. w/h <= 0 = non cambiare dimensione.
	 * Subito dopo rilascia cattura/gabbia del mouse che SDL puo' aver riapplicato.
	 */
	@:functionCode('
		static HWND game = NULL;
		if (game == NULL || !IsWindow(game))
		{
			game = NULL;
			HWND cur = NULL;
			DWORD pid = GetCurrentProcessId();
			while ((cur = FindWindowExW(NULL, cur, L"SDL_app", NULL)) != NULL)
			{
				DWORD wp = 0;
				GetWindowThreadProcessId(cur, &wp);
				if (wp == pid) { game = cur; break; }
			}
			if (game == NULL) return;
		}
		bool keepSize = (w <= 0 || hgt <= 0);
		int cw = w, ch = hgt;
		if (keepSize)
		{
			RECT c; GetClientRect(game, &c);
			cw = c.right; ch = c.bottom;
		}
		DWORD style = (DWORD)GetWindowLongPtrW(game, GWL_STYLE);
		DWORD ex = (DWORD)GetWindowLongPtrW(game, GWL_EXSTYLE);
		RECT rc; rc.left = x; rc.top = y; rc.right = x + cw; rc.bottom = y + ch;
		AdjustWindowRectEx(&rc, style, FALSE, ex);
		UINT flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER;
		if (keepSize) flags |= SWP_NOSIZE;
		SetWindowPos(game, NULL, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top, flags);
		if (GetCapture() != NULL) ReleaseCapture();
		ClipCursor(NULL);
	')
	public static function setGameRect(x:Int, y:Int, w:Int, hgt:Int):Void {}

	/** Libera il mouse (cattura + gabbia). Utile da chiamare ogni tanto come rete di sicurezza. */
	@:functionCode('
		if (GetCapture() != NULL) ReleaseCapture();
		ClipCursor(NULL);
	')
	public static function releaseMouse():Void {}

	/**
	 * Guardia del mouse, da chiamare ogni frame. Toglie:
	 *  - una cattura (SetCapture) rimasta appesa con nessun tasto premuto
	 *  - una gabbia (ClipCursor) piu' piccola dello schermo
	 * Ritorna una maschera: 1 = cattura rilasciata, 2 = gabbia rilasciata.
	 */
	@:functionCode('
		int mask = 0;
		bool down = ((GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) || ((GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0) || ((GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0);
		if (GetCapture() != NULL && !down) { ReleaseCapture(); mask |= 1; }
		RECT cr;
		if (GetClipCursor(&cr))
		{
			int vl = GetSystemMetrics(SM_XVIRTUALSCREEN);
			int vt = GetSystemMetrics(SM_YVIRTUALSCREEN);
			int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
			int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
			if (cr.left > vl || cr.top > vt || cr.right < vl + vw || cr.bottom < vt + vh) { ClipCursor(NULL); mask |= 2; }
		}
		return mask;
	')
	public static function freeMouse():Int
	{
		return 0;
	}

	/** Solo diagnostica (non modifica nulla): 1 = cattura attiva, 2 = gabbia attiva, 4 = tasto premuto. */
	@:functionCode('
		int mask = 0;
		if (GetCapture() != NULL) mask |= 1;
		RECT cr;
		if (GetClipCursor(&cr))
		{
			int vl = GetSystemMetrics(SM_XVIRTUALSCREEN);
			int vt = GetSystemMetrics(SM_YVIRTUALSCREEN);
			int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
			int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
			if (cr.left > vl || cr.top > vt || cr.right < vl + vw || cr.bottom < vt + vh) mask |= 2;
		}
		if (((GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) || ((GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0)) mask |= 4;
		return mask;
	')
	public static function mouseState():Int
	{
		return 0;
	}

	/**
	 * Disegna il buffer (4 byte per pixel, ordine canali dato da iA/iR/iG/iB)
	 * nella finestra. Se layered -> trasparenza per pixel.
	 * Usa un DIB in cache per finestra e un ciclo veloce per l'ordine ARGB piu' comune.
	 */
	@:functionCode('
		HWND hwnd = (HWND)(intptr_t)hnd;
		if (!IsWindow(hwnd) || w <= 0 || hgt <= 0) return;

		const unsigned char* src = (const unsigned char*)data->getBase();

		BITMAPINFO bi;
		ZeroMemory(&bi, sizeof(bi));
		bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
		bi.bmiHeader.biWidth = w;
		bi.bmiHeader.biHeight = -hgt;
		bi.bmiHeader.biPlanes = 1;
		bi.bmiHeader.biBitCount = 32;
		bi.bmiHeader.biCompression = BI_RGB;

		PsychBuf* pb = PsychGetBuf(hwnd, w, hgt, &bi);
		if (pb == NULL) return;
		if (g_screenDC == NULL) g_screenDC = GetDC(NULL);

		unsigned char* dst = (unsigned char*)pb->bits;
		int n = w * hgt;

		if (layered && !srcPremult && iA == 0 && iR == 1 && iG == 2 && iB == 3)
		{
			for (int i = 0; i < n; i++)
			{
				const unsigned char* s = src + i * 4;
				unsigned char* d = dst + i * 4;
				unsigned int a = s[0];
				if (a == 255) { d[0] = s[3]; d[1] = s[2]; d[2] = s[1]; d[3] = 255; }
				else if (a == 0) { d[0] = 0; d[1] = 0; d[2] = 0; d[3] = 0; }
				else
				{
					d[0] = (unsigned char)((s[3] * a + 127) / 255);
					d[1] = (unsigned char)((s[2] * a + 127) / 255);
					d[2] = (unsigned char)((s[1] * a + 127) / 255);
					d[3] = (unsigned char)a;
				}
			}
		}
		else
		{
			for (int i = 0; i < n; i++)
			{
				const unsigned char* s = src + i * 4;
				unsigned char* d = dst + i * 4;
				unsigned int a = s[iA];
				unsigned int r = s[iR];
				unsigned int g = s[iG];
				unsigned int b = s[iB];
				if (layered)
				{
					if (!srcPremult)
					{
						r = (r * a + 127) / 255;
						g = (g * a + 127) / 255;
						b = (b * a + 127) / 255;
					}
					d[0] = (unsigned char)b; d[1] = (unsigned char)g; d[2] = (unsigned char)r; d[3] = (unsigned char)a;
				}
				else
				{
					d[0] = (unsigned char)b; d[1] = (unsigned char)g; d[2] = (unsigned char)r; d[3] = 255;
				}
			}
		}

		if (layered)
		{
			SIZE sz; sz.cx = w; sz.cy = hgt;
			POINT zero; zero.x = 0; zero.y = 0;
			BLENDFUNCTION bf;
			bf.BlendOp = AC_SRC_OVER;
			bf.BlendFlags = 0;
			bf.SourceConstantAlpha = 255;
			bf.AlphaFormat = AC_SRC_ALPHA;
			UpdateLayeredWindow(hwnd, g_screenDC, NULL, &sz, pb->dc, &zero, 0, &bf, ULW_ALPHA);
		}
		else
		{
			HDC wdc = GetDC(hwnd);
			RECT cr; GetClientRect(hwnd, &cr);
			StretchDIBits(wdc, 0, 0, cr.right, cr.bottom, 0, 0, w, hgt, pb->bits, &bi, DIB_RGB_COLORS, SRCCOPY);
			ReleaseDC(hwnd, wdc);
		}
	')
	public static function present(hnd:Int, data:haxe.io.BytesData, w:Int, hgt:Int, layered:Bool, iA:Int, iR:Int, iG:Int, iB:Int, srcPremult:Bool):Void {}
}
#end
