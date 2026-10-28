package;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.graphics.frames.FlxFrame;
import flixel.util.FlxColor;
import haxe.io.Bytes;
import lime.app.Application;
import openfl.display.BitmapData;
import openfl.geom.Matrix;
import openfl.utils.ByteArray;
#if LUA_ALLOWED
import llua.Lua;
#end

using StringTools;

typedef WinItem =
{
	var tag:String;
	var spr:FlxSprite;
	var fixed:Bool; // true = posizione fissa nella finestra (fx, fy); false = posizione "mondo" (spr.x - viewX)
	var fx:Float;
	var fy:Float;
	// cache dell'ultimo stato disegnato (per ridisegnare solo se cambia qualcosa)
	var cFrame:FlxFrame;
	var cPx:Float;
	var cPy:Float;
	var cSx:Float;
	var cSy:Float;
	var cAng:Float;
	var cOx:Float;
	var cOy:Float;
	var cAlpha:Float;
	var cColor:Int;
	var cFlipX:Bool;
	var cFlipY:Bool;
	var cAA:Bool;
}

typedef WinData =
{
	var tag:String;
	var handle:Int;
	var w:Int;
	var h:Int;
	var layered:Bool; // trasparenza per pixel
	var borderless:Bool;
	var clickThrough:Bool;
	var bg:Int; // colore di sfondo ARGB
	var viewX:Float;
	var viewY:Float;
	var canvas:BitmapData;
	var buf:ByteArray;
	var items:Array<WinItem>;
	var dirty:Bool; // forza il prossimo ridisegno
	var idle:Int; // frame passati senza cambiamenti
	var lvx:Float;
	var lvy:Float;
	var lbg:Int;
	var lw:Int;
	var lh:Int;
	var lcount:Int;
}

/**
 * API Lua per aprire finestre extra di Windows e metterci dentro gli sprite.
 * Si registra con WindowFunctions.implement(this) dentro FunkinLua.
 * La parte nativa e' in WinNative.hx (solo Windows).
 */
class WindowFunctions
{
	public static var windows:Map<String, WinData> = new Map<String, WinData>();

	static var hooked:Bool = false;

	// Guardia del mouse: ogni frame toglie SetCapture appesi / ClipCursor che trascinano il cursore
	static var mouseGuard:Bool = true;
	static var guardWarned:Int = 0;

	static var mtx:Matrix = new Matrix();

	static inline var FORCE_REDRAW_EVERY:Int = 30; // ridisegno di sicurezza se nulla cambia

	// Ordine dei canali restituito da BitmapData.copyPixelsToByteArray (calibrato a runtime)
	static var iA:Int = 0;
	static var iR:Int = 1;
	static var iG:Int = 2;
	static var iB:Int = 3;
	static var srcPremult:Bool = false;
	static var calibrated:Bool = false;

	// ------------------------------------------------------------------
	//  Utility
	// ------------------------------------------------------------------

	static function calibrate():Void
	{
		if (calibrated) return;
		calibrated = true;
		try
		{
			var bd = new BitmapData(2, 1, true, 0);
			bd.setPixel32(0, 0, 0xFF112233);
			bd.setPixel32(1, 0, 0x80FF8040);
			var ba:ByteArray = bd.getPixels(bd.rect);
			var b:Array<Int> = [for (i in 0...8) ba[i]];
			bd.dispose();

			var a = b.indexOf(0xFF);
			var r = b.indexOf(0x11);
			var g = b.indexOf(0x22);
			var bl = b.indexOf(0x33);
			if (a >= 0 && a < 4 && r >= 0 && r < 4 && g >= 0 && g < 4 && bl >= 0 && bl < 4)
			{
				iA = a;
				iR = r;
				iG = g;
				iB = bl;
				// secondo pixel: se R (che era 0xFF) e' sceso, il buffer e' premoltiplicato
				srcPremult = b[4 + iR] < 200;
			}
		}
		catch (e:Dynamic)
		{
			trace('WindowFunctions: calibrazione fallita, uso ARGB di default ($e)');
		}
	}

	static function hook():Void
	{
		if (hooked) return;
		hooked = true;
		FlxG.signals.postUpdate.add(update);
	}

	static function parseColor(hex:String, alpha:Float):Int
	{
		hex = hex.trim().replace('#', '').replace('0x', '').replace('0X', '');
		var rgb:Null<Int> = Std.parseInt('0x' + hex);
		if (rgb == null) rgb = 0;
		var a:Int = Std.int(Math.max(0, Math.min(1, alpha)) * 255);
		return (a << 24) | (rgb & 0xFFFFFF);
	}

	static function findSprite(tag:String):FlxSprite
	{
		var o:Dynamic = FunkinLua.getObjectDirectly(tag, false);
		if (o != null && Std.isOfType(o, FlxSprite)) return cast o;
		return null;
	}

	static inline function gameScale():Float
	{
		var win = Application.current.window;
		return Math.min(win.width / FlxG.width, win.height / FlxG.height);
	}

	static function gameToScreenX(x:Float):Float
	{
		var win = Application.current.window;
		var sc = gameScale();
		return win.x + (win.width - FlxG.width * sc) * 0.5 + x * sc;
	}

	static function gameToScreenY(y:Float):Float
	{
		var win = Application.current.window;
		var sc = gameScale();
		return win.y + (win.height - FlxG.height * sc) * 0.5 + y * sc;
	}

	/** Posizione (angolo alto-sinistra del frame) dello sprite nello spazio 1280x720 del gioco, camera e zoom inclusi. */
	static function spriteGamePos(spr:FlxSprite):{x:Float, y:Float}
	{
		var cam = (spr.cameras != null && spr.cameras.length > 0) ? spr.cameras[0] : FlxG.camera;
		var px = spr.x - spr.offset.x - cam.scroll.x * spr.scrollFactor.x;
		var py = spr.y - spr.offset.y - cam.scroll.y * spr.scrollFactor.y;
		var z = cam.zoom;
		return {
			x: cam.x + (px - cam.width * 0.5) * z + cam.width * 0.5,
			y: cam.y + (py - cam.height * 0.5) * z + cam.height * 0.5
		};
	}

	// ------------------------------------------------------------------
	//  Gestione finestre
	// ------------------------------------------------------------------

	public static function create(tag:String, title:String, x:Float, y:Float, w:Float, h:Float, borderless:Bool, transparent:Bool):Bool
	{
		#if windows
		if (windows.exists(tag)) close(tag);

		var iw = Std.int(Math.max(1, Math.round(w)));
		var ih = Std.int(Math.max(1, Math.round(h)));
		var hnd = WinNative.createWin(title, Math.round(x), Math.round(y), iw, ih, borderless, false, transparent);
		if (hnd == 0) return false;

		calibrate();
		var d:WinData = {
			tag: tag,
			handle: hnd,
			w: iw,
			h: ih,
			layered: transparent,
			borderless: borderless || transparent,
			clickThrough: false,
			bg: transparent ? 0x00000000 : 0xFF000000,
			viewX: 0,
			viewY: 0,
			canvas: new BitmapData(iw, ih, true, 0),
			buf: new ByteArray(),
			items: [],
			dirty: true,
			idle: 0,
			lvx: 0,
			lvy: 0,
			lbg: 0,
			lw: 0,
			lh: 0,
			lcount: -1
		};
		windows.set(tag, d);
		hook();
		render(d, true);
		return true;
		#else
		return false;
		#end
	}

	public static function close(tag:String):Void
	{
		#if windows
		var d = windows.get(tag);
		if (d == null) return;
		windows.remove(tag);
		if (d.canvas != null) d.canvas.dispose();
		WinNative.destroyWin(d.handle);
		#end
	}

	public static function closeAll():Void
	{
		#if windows
		var tags = [for (t in windows.keys()) t];
		for (t in tags) close(t);
		#end
	}

	/** Chiamato a ogni frame (FlxG.signals.postUpdate): ridisegna tutte le finestre. */
	public static function update():Void
	{
		#if windows
		if (mouseGuard)
		{
			var r = WinNative.freeMouse();
			if (r != 0 && guardWarned < 3)
			{
				guardWarned++;
				trace('WindowFunctions: mouse liberato (' + ((r & 1) != 0 ? 'cattura ' : '') + ((r & 2) != 0 ? 'gabbia-cursore' : '') + ')');
			}
		}

		var dead:Array<String> = null;
		for (tag => d in windows)
		{
			if (!WinNative.isAlive(d.handle))
			{
				if (dead == null) dead = [];
				dead.push(tag);
				continue;
			}
			render(d);
		}

		if (dead != null)
		{
			for (tag in dead)
			{
				var d = windows.get(tag);
				if (d != null && d.canvas != null) d.canvas.dispose();
				windows.remove(tag);
				// chiusa dall'utente con la X
				if (PlayState.instance != null) PlayState.instance.callOnLuas('onWindowClosed', [tag]);
			}
		}
		#end
	}

	static function newItem(tag:String, spr:FlxSprite, fixed:Bool, fx:Float, fy:Float):WinItem
	{
		return {
			tag: tag,
			spr: spr,
			fixed: fixed,
			fx: fx,
			fy: fy,
			cFrame: null,
			cPx: -99999,
			cPy: -99999,
			cSx: 0,
			cSy: 0,
			cAng: 0,
			cOx: 0,
			cOy: 0,
			cAlpha: -1,
			cColor: 0,
			cFlipX: false,
			cFlipY: false,
			cAA: false
		};
	}

	/** Confronta lo stato attuale dello sprite con l'ultimo disegnato e aggiorna la cache. */
	static function itemChanged(it:WinItem, spr:FlxSprite, px:Float, py:Float):Bool
	{
		var ch = false;
		var col:Int = spr.color;
		if (it.cFrame != spr.frame) { it.cFrame = spr.frame; ch = true; }
		if (it.cPx != px) { it.cPx = px; ch = true; }
		if (it.cPy != py) { it.cPy = py; ch = true; }
		if (it.cSx != spr.scale.x) { it.cSx = spr.scale.x; ch = true; }
		if (it.cSy != spr.scale.y) { it.cSy = spr.scale.y; ch = true; }
		if (it.cAng != spr.angle) { it.cAng = spr.angle; ch = true; }
		if (it.cOx != spr.origin.x) { it.cOx = spr.origin.x; ch = true; }
		if (it.cOy != spr.origin.y) { it.cOy = spr.origin.y; ch = true; }
		if (it.cAlpha != spr.alpha) { it.cAlpha = spr.alpha; ch = true; }
		if (it.cColor != col) { it.cColor = col; ch = true; }
		if (it.cFlipX != spr.flipX) { it.cFlipX = spr.flipX; ch = true; }
		if (it.cFlipY != spr.flipY) { it.cFlipY = spr.flipY; ch = true; }
		if (it.cAA != spr.antialiasing) { it.cAA = spr.antialiasing; ch = true; }
		return ch;
	}

	/**
	 * Ridisegna la finestra SOLO se qualcosa e' cambiato (sprite mosso, nuovo frame
	 * d'animazione, scala, colore...). Se e' tutto fermo non fa nulla: niente
	 * conversione pixel, niente UpdateLayeredWindow. Spostare la finestra
	 * (setWindowPos) non richiede nessun ridisegno.
	 */
	static function render(d:WinData, force:Bool = false):Void
	{
		#if windows
		var changed = force || d.dirty || d.viewX != d.lvx || d.viewY != d.lvy || d.bg != d.lbg || d.w != d.lw || d.h != d.lh;

		var count = 0;
		for (it in d.items)
		{
			var spr = it.spr;
			if (spr == null || !spr.exists || spr.frame == null) continue;
			count++;
			var px:Float = (it.fixed ? it.fx : (spr.x - d.viewX)) - spr.offset.x;
			var py:Float = (it.fixed ? it.fy : (spr.y - d.viewY)) - spr.offset.y;
			if (itemChanged(it, spr, px, py)) changed = true;
		}
		if (count != d.lcount) changed = true;

		if (!changed)
		{
			d.idle++;
			if (d.idle < FORCE_REDRAW_EVERY) return;
		}
		d.idle = 0;
		d.dirty = false;
		d.lvx = d.viewX;
		d.lvy = d.viewY;
		d.lbg = d.bg;
		d.lw = d.w;
		d.lh = d.h;
		d.lcount = count;

		var c = d.canvas;
		c.fillRect(c.rect, d.bg);

		for (it in d.items)
		{
			var spr = it.spr;
			if (spr == null || !spr.exists || spr.frame == null) continue;

			var src:BitmapData = null;
			try
			{
				src = spr.updateFramePixels();
			}
			catch (e:Dynamic) {}
			if (src == null) src = spr.framePixels;
			if (src == null) continue;

			var px:Float = (it.fixed ? it.fx : (spr.x - d.viewX)) - spr.offset.x;
			var py:Float = (it.fixed ? it.fy : (spr.y - d.viewY)) - spr.offset.y;

			mtx.identity();
			mtx.translate(-spr.origin.x, -spr.origin.y);
			mtx.scale(spr.scale.x, spr.scale.y);
			if (spr.angle != 0) mtx.rotate(spr.angle * Math.PI / 180);
			mtx.translate(spr.origin.x + px, spr.origin.y + py);

			try
			{
				c.draw(src, mtx, null, null, null, spr.antialiasing);
			}
			catch (e:Dynamic) {}
		}

		// buffer riusato (prima: getPixels() allocava ~3.7 MB nuovi a ogni frame -> GC -> lag)
		var ba:ByteArray = d.buf;
		ba.position = 0;
		c.copyPixelsToByteArray(c.rect, ba);
		if (ba.length >= d.w * d.h * 4)
		{
			var bytes:Bytes = cast ba;
			WinNative.present(d.handle, bytes.getData(), d.w, d.h, d.layered, iA, iR, iG, iB, srcPremult);
		}
		#end
	}

	// ------------------------------------------------------------------
	//  Registrazione callback Lua
	// ------------------------------------------------------------------

	public static function implement(funk:FunkinLua):Void
	{
		#if LUA_ALLOWED
		var lua = funk.lua;
		#if windows
		hook(); // la guardia del mouse deve girare anche senza finestre extra
		#end

		#if !windows
		Lua_helper.add_callback(lua, "createWindow", function(tag:String, title:String, x:Float, y:Float, w:Float, h:Float, ?borderless:Bool = false, ?transparent:Bool = false) {
			funk.luaTrace('createWindow: le finestre extra funzionano solo su Windows!', true, false, FlxColor.RED);
			return false;
		});
		#else

		// ---------- finestre ----------

		Lua_helper.add_callback(lua, "createWindow", function(tag:String, title:String, x:Float, y:Float, w:Float, h:Float, ?borderless:Bool = false, ?transparent:Bool = false) {
			var ok = create(tag, title, x, y, w, h, borderless, transparent);
			if (!ok) funk.luaTrace('createWindow: impossibile creare la finestra "$tag"', false, false, FlxColor.RED);
			return ok;
		});

		Lua_helper.add_callback(lua, "closeWindow", function(tag:String) {
			close(tag);
		});

		Lua_helper.add_callback(lua, "closeAllWindows", function() {
			closeAll();
		});

		Lua_helper.add_callback(lua, "windowExists", function(tag:String) {
			var d = windows.get(tag);
			return d != null && WinNative.isAlive(d.handle);
		});

		Lua_helper.add_callback(lua, "setWindowPos", function(tag:String, x:Float, y:Float) {
			var d = windows.get(tag);
			if (d == null) return false;
			WinNative.setPos(d.handle, Math.round(x), Math.round(y));
			return true;
		});

		Lua_helper.add_callback(lua, "getWindowX", function(tag:String) {
			var d = windows.get(tag);
			return d == null ? 0 : WinNative.getPosX(d.handle);
		});

		Lua_helper.add_callback(lua, "getWindowY", function(tag:String) {
			var d = windows.get(tag);
			return d == null ? 0 : WinNative.getPosY(d.handle);
		});

		Lua_helper.add_callback(lua, "setWindowSize", function(tag:String, w:Float, h:Float) {
			var d = windows.get(tag);
			if (d == null) return false;
			var iw = Std.int(Math.max(1, Math.round(w)));
			var ih = Std.int(Math.max(1, Math.round(h)));
			if (iw == d.w && ih == d.h) return true;
			d.w = iw;
			d.h = ih;
			if (d.canvas != null) d.canvas.dispose();
			d.canvas = new BitmapData(iw, ih, true, 0);
			d.dirty = true;
			WinNative.setSize(d.handle, iw, ih);
			return true;
		});

		Lua_helper.add_callback(lua, "getWindowWidth", function(tag:String) {
			var d = windows.get(tag);
			return d == null ? 0 : d.w;
		});

		Lua_helper.add_callback(lua, "getWindowHeight", function(tag:String) {
			var d = windows.get(tag);
			return d == null ? 0 : d.h;
		});

		Lua_helper.add_callback(lua, "setWindowTitle", function(tag:String, title:String) {
			var d = windows.get(tag);
			if (d == null) return false;
			WinNative.setTitle(d.handle, title);
			return true;
		});

		Lua_helper.add_callback(lua, "setWindowBorderless", function(tag:String, on:Bool) {
			var d = windows.get(tag);
			if (d == null) return false;
			if (!on && d.layered)
			{
				funk.luaTrace('setWindowBorderless: una finestra trasparente non puo\' avere il bordo', false, false, FlxColor.RED);
				return false;
			}
			d.borderless = on;
			WinNative.setBorderless(d.handle, on);
			return true;
		});

		Lua_helper.add_callback(lua, "setWindowAlwaysOnTop", function(tag:String, on:Bool) {
			var d = windows.get(tag);
			if (d == null) return false;
			WinNative.setTopmost(d.handle, on);
			return true;
		});

		// Trasparenza PER PIXEL (niente colore chiave, niente aloni).
		// Lo sfondo diventa trasparente e la finestra perde bordo/titolo.
		Lua_helper.add_callback(lua, "setWindowTransparent", function(tag:String, on:Bool) {
			var d = windows.get(tag);
			if (d == null) return false;
			if (d.layered == on) return true;
			d.layered = on;
			WinNative.setLayered(d.handle, on);
			if (on)
			{
				if (!d.borderless)
				{
					d.borderless = true;
					WinNative.setBorderless(d.handle, true);
				}
				if ((d.bg >>> 24) == 0xFF && (d.bg & 0xFFFFFF) == 0) d.bg = 0x00000000;
			}
			else
			{
				if (d.clickThrough)
				{
					d.clickThrough = false;
					WinNative.setClickThrough(d.handle, false);
				}
				if ((d.bg >>> 24) == 0) d.bg = 0xFF000000;
			}
			render(d, true);
			return true;
		});

		// Il mouse "attraversa" la finestra (utile per sprite decorativi sul desktop).
		// Se la finestra non e' trasparente, lo diventa.
		Lua_helper.add_callback(lua, "setWindowClickThrough", function(tag:String, on:Bool) {
			var d = windows.get(tag);
			if (d == null) return false;
			if (on && !d.layered)
			{
				d.layered = true;
				WinNative.setLayered(d.handle, true);
				if (!d.borderless)
				{
					d.borderless = true;
					WinNative.setBorderless(d.handle, true);
				}
				if ((d.bg >>> 24) == 0xFF && (d.bg & 0xFFFFFF) == 0) d.bg = 0x00000000;
			}
			d.clickThrough = on;
			WinNative.setClickThrough(d.handle, on);
			render(d, true);
			return true;
		});

		// Colore di sfondo es. setWindowBackground('w', '00FF00') ; alpha 0 = trasparente (solo se la finestra e' trasparente)
		Lua_helper.add_callback(lua, "setWindowBackground", function(tag:String, hex:String, ?alpha:Float = 1) {
			var d = windows.get(tag);
			if (d == null) return false;
			d.bg = parseColor(hex, alpha);
			return true;
		});

		// ---------- sprite dentro le finestre ----------

		// addSpriteToWindow('boyfriend', 'w')           -> modalita' "mondo": lo sprite e' disegnato in (spr.x - viewX, spr.y - viewY)
		// addSpriteToWindow('boyfriend', 'w', 20, 30)   -> posizione fissa dentro la finestra
		// Funziona con boyfriend, dad, gf, sprite creati con makeLuaSprite/makeAnimatedLuaSprite
		// (anche se NON aggiunti al gioco con addLuaSprite) e qualsiasi oggetto FlxSprite raggiungibile da Lua.
		Lua_helper.add_callback(lua, "addSpriteToWindow", function(spriteTag:String, windowTag:String, ?x:Null<Float> = null, ?y:Null<Float> = null) {
			var d = windows.get(windowTag);
			if (d == null)
			{
				funk.luaTrace('addSpriteToWindow: la finestra "$windowTag" non esiste', false, false, FlxColor.RED);
				return false;
			}
			var spr = findSprite(spriteTag);
			if (spr == null)
			{
				funk.luaTrace('addSpriteToWindow: lo sprite "$spriteTag" non esiste', false, false, FlxColor.RED);
				return false;
			}
			for (it in d.items)
			{
				if (it.tag == spriteTag)
				{
					it.spr = spr;
					it.fixed = (x != null);
					if (x != null) it.fx = x;
					if (y != null) it.fy = y;
					d.dirty = true;
					return true;
				}
			}
			d.items.push(newItem(spriteTag, spr, (x != null), (x != null) ? x : 0, (y != null) ? y : 0));
			d.dirty = true;
			return true;
		});

		Lua_helper.add_callback(lua, "removeSpriteFromWindow", function(spriteTag:String, windowTag:String) {
			var d = windows.get(windowTag);
			if (d == null) return false;
			for (it in d.items)
			{
				if (it.tag == spriteTag)
				{
					d.items.remove(it);
					d.dirty = true;
					return true;
				}
			}
			return false;
		});

		// Sposta lo sprite dentro la finestra (lo mette in modalita' "posizione fissa")
		Lua_helper.add_callback(lua, "setSpriteInWindowPos", function(spriteTag:String, windowTag:String, x:Float, y:Float) {
			var d = windows.get(windowTag);
			if (d == null) return false;
			for (it in d.items)
			{
				if (it.tag == spriteTag)
				{
					it.fixed = true;
					it.fx = x;
					it.fy = y;
					return true;
				}
			}
			return false;
		});

		// Inquadratura per gli sprite in modalita' "mondo": la finestra mostra la zona che parte da (x, y) del mondo di gioco
		Lua_helper.add_callback(lua, "setWindowView", function(tag:String, x:Float, y:Float) {
			var d = windows.get(tag);
			if (d == null) return false;
			d.viewX = x;
			d.viewY = y;
			return true;
		});

		// ---------- schermo / finestra di gioco ----------

		// Sposta/ridimensiona la finestra VERA del gioco con UNA chiamata (coordinate come window.x/y/width/height).
		// w/h = 0 -> solo spostamento. Sostituisce i 4 setPropertyFromClass(...application.window...) per frame.
		Lua_helper.add_callback(lua, "setGameWindowRect", function(x:Float, y:Float, ?w:Float = 0, ?h:Float = 0) {
			if (Application.current.window.fullscreen) return false;
			WinNative.setGameRect(Math.round(x), Math.round(y), Math.round(w), Math.round(h));
			return true;
		});

		// Rete di sicurezza: libera cattura/gabbia del mouse subito
		Lua_helper.add_callback(lua, "releaseMouse", function() {
			WinNative.freeMouse();
		});

		// Accende/spegne la guardia automatica del mouse (default: accesa)
		Lua_helper.add_callback(lua, "setMouseGuard", function(on:Bool) {
			mouseGuard = on;
		});

		// Diagnostica: stampa se il mouse e' catturato (1) / ingabbiato (2) / tasto premuto (4)
		Lua_helper.add_callback(lua, "debugMouse", function() {
			var m = WinNative.mouseState();
			funk.luaTrace('debugMouse: catturato=' + ((m & 1) != 0) + ' ingabbiato=' + ((m & 2) != 0) + ' tasto=' + ((m & 4) != 0), false, false, FlxColor.YELLOW);
			return m;
		});

		// Forza il ridisegno di una finestra (es. se hai ridisegnato i pixel di uno sprite a mano)
		Lua_helper.add_callback(lua, "redrawWindow", function(tag:String) {
			var d = windows.get(tag);
			if (d == null) return false;
			d.dirty = true;
			return true;
		});

		Lua_helper.add_callback(lua, "getScreenWidth", function() {
			return WinNative.screenWidth();
		});

		Lua_helper.add_callback(lua, "getScreenHeight", function() {
			return WinNative.screenHeight();
		});

		Lua_helper.add_callback(lua, "getGameWindowX", function() {
			return Application.current.window.x;
		});

		Lua_helper.add_callback(lua, "getGameWindowY", function() {
			return Application.current.window.y;
		});

		Lua_helper.add_callback(lua, "getGameWindowWidth", function() {
			return Application.current.window.width;
		});

		Lua_helper.add_callback(lua, "getGameWindowHeight", function() {
			return Application.current.window.height;
		});

		// Scala tra lo spazio di gioco (1280x720) e i pixel reali dello schermo
		Lua_helper.add_callback(lua, "getGameScale", function() {
			return gameScale();
		});

		// Coordinate di gioco (0..1280 / 0..720, quelle che vedi a schermo) -> coordinate schermo
		Lua_helper.add_callback(lua, "gameToScreenX", function(x:Float) {
			return gameToScreenX(x);
		});

		Lua_helper.add_callback(lua, "gameToScreenY", function(y:Float) {
			return gameToScreenY(y);
		});

		// Posizione sullo SCHERMO (angolo alto-sinistra del frame) di un oggetto di gioco, con camera e zoom
		Lua_helper.add_callback(lua, "getObjectScreenX", function(obj:String) {
			var spr = findSprite(obj);
			if (spr == null) return 0.0;
			return gameToScreenX(spriteGamePos(spr).x);
		});

		Lua_helper.add_callback(lua, "getObjectScreenY", function(obj:String) {
			var spr = findSprite(obj);
			if (spr == null) return 0.0;
			return gameToScreenY(spriteGamePos(spr).y);
		});

		#end // windows
		#end // LUA_ALLOWED
	}
}
