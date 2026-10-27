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
			wc.lpfnWndProc = DefWindowProcW;
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
		if (layered) ex |= WS_EX_LAYERED;

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
		SetWindowPos(hwnd, NULL, x - offX, y - offY, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
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
	 * Disegna il buffer (4 byte per pixel, ordine canali dato da iA/iR/iG/iB)
	 * nella finestra. Se layered -> trasparenza per pixel.
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

		HDC screenDC = GetDC(NULL);
		void* bits = NULL;
		HBITMAP bmp = CreateDIBSection(screenDC, &bi, DIB_RGB_COLORS, &bits, NULL, 0);

		if (bmp != NULL && bits != NULL)
		{
			unsigned char* dst = (unsigned char*)bits;
			int n = w * hgt;
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
					d[0] = (unsigned char)b;
					d[1] = (unsigned char)g;
					d[2] = (unsigned char)r;
					d[3] = (unsigned char)a;
				}
				else
				{
					d[0] = (unsigned char)b;
					d[1] = (unsigned char)g;
					d[2] = (unsigned char)r;
					d[3] = 255;
				}
			}

			if (layered)
			{
				HDC memDC = CreateCompatibleDC(screenDC);
				HGDIOBJ oldObj = SelectObject(memDC, bmp);
				SIZE sz; sz.cx = w; sz.cy = hgt;
				POINT zero; zero.x = 0; zero.y = 0;
				BLENDFUNCTION bf;
				bf.BlendOp = AC_SRC_OVER;
				bf.BlendFlags = 0;
				bf.SourceConstantAlpha = 255;
				bf.AlphaFormat = AC_SRC_ALPHA;
				UpdateLayeredWindow(hwnd, screenDC, NULL, &sz, memDC, &zero, 0, &bf, ULW_ALPHA);
				SelectObject(memDC, oldObj);
				DeleteDC(memDC);
			}
			else
			{
				HDC wdc = GetDC(hwnd);
				RECT cr; GetClientRect(hwnd, &cr);
				StretchDIBits(wdc, 0, 0, cr.right, cr.bottom, 0, 0, w, hgt, bits, &bi, DIB_RGB_COLORS, SRCCOPY);
				ReleaseDC(hwnd, wdc);
			}
		}

		if (bmp != NULL) DeleteObject(bmp);
		ReleaseDC(NULL, screenDC);
	')
	public static function present(hnd:Int, data:haxe.io.BytesData, w:Int, hgt:Int, layered:Bool, iA:Int, iR:Int, iG:Int, iB:Int, srcPremult:Bool):Void {}
}
#end
