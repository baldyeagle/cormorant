import WebKit

/// Follows the color at the top of the page while it scrolls, so the status-bar strip keeps up with a
/// sticky header that changes color, as Safari's does. Snapshots are too costly to take every frame;
/// this reads the page instead: a script in its own content world (pages can't see, call or replace
/// it, and their Content-Security-Policy doesn't apply to it) finds what's painted under the top edge,
/// at most once a frame while scrolling, and posts the color only when it changes.
///
/// It's an estimate. Computed colors know nothing of images, gradients, canvas or frames; for those it
/// reports "unknown" and the session takes a snapshot instead. The snapshot taken once scrolling rests
/// has the last word either way.
///
/// The script sits idle unless its tab is on screen and "Tint with Website Colors" is on; it asks when
/// it starts and is told when that changes. Link previews and pages loading on the background stage
/// never run it (`setActive`).
@MainActor
final class PageTopTracker: NSObject, WKScriptMessageHandlerWithReply {
    static let world = WKContentWorld.world(name: "CormorantPageTop")
    static let handlerName = "cormorantPageTop"

    weak var session: TabSession?

    /// Installs the script and its message handler for future documents in `contentController`.
    func install(in contentController: WKUserContentController) {
        contentController.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentEnd,
                                                     forMainFrameOnly: true, in: Self.world))
        contentController.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.handlerName)
    }

    /// Runs the script in the document already loaded (a web view adopted from a link preview).
    func inject(into webView: WKWebView) {
        webView.evaluateJavaScript(Self.source, in: nil, in: Self.world, completionHandler: nil)
    }

    /// Starts or stops tracking in the current document.
    func setActive(_ active: Bool, in webView: WKWebView) {
        webView.evaluateJavaScript("Object.hasOwn(window, \"__cormorantPageTop\") && window.__cormorantPageTop.setActive(\(active))",
                                   in: nil, in: Self.world, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else {
            replyHandler(nil, nil)
            return
        }
        if body["ready"] != nil {
            replyHandler(session?.tracksPageTopLive ?? false, nil)
            return
        }
        // [r, g, b, a] in 0...1, alpha below 1 when what's painted lets the canvas through; null when
        // the top is a picture, a frame or a mix. A baseline is where tracking started, not a change.
        let components = (body["color"] as? [NSNumber])?.map(\.doubleValue)
        session?.pageTopDidChange(components?.count == 4 ? components : nil, isBaseline: body["baseline"] as? Bool == true)
        replyHandler(nil, nil)
    }

    /// Kept small and allocation-light: it runs on scroll. Reads only computed backgrounds of the
    /// elements under five points of the top edge (no layout of its own).
    static let source = #"""
    (() => {
      // An own property, so a page element named or id'd "__cormorantPageTop" can't shadow it.
      if (Object.hasOwn(window, "__cormorantPageTop")) return;
      const handler = window.webkit.messageHandlers.cormorantPageTop;
      // From the prototype: a <form name="elementsFromPoint"> can shadow document's own.
      const elementsFromPoint = Document.prototype.elementsFromPoint;
      const pictures = new Set(["IMG", "VIDEO", "CANVAS", "IFRAME", "FRAME", "EMBED", "OBJECT", "svg", "SVG", "PICTURE"]);
      let active = false, last = "", frame = 0, trailing = [], lastPost = 0, throttled = 0;

      // Computed backgrounds serialize as rgb()/rgba() for sRGB, or keep their space (oklch(),
      // lab(), color(display-p3 ...)): those are drawn into a 1x1 sRGB canvas and read back, once each.
      const converted = new Map();
      let pixel;
      const parse = (s) => {
        const m = /^rgba?\(([^)]*)\)$/.exec(s);
        if (m) {
          const p = m[1].split(/[\s,\/]+/).filter(Boolean).map(Number);
          if (p.length < 3 || p.some(Number.isNaN)) return null;
          return [p[0] / 255, p[1] / 255, p[2] / 255, p.length > 3 ? p[3] : 1];
        }
        if (converted.has(s)) return converted.get(s);
        pixel = pixel || document.createElement("canvas").getContext("2d", { colorSpace: "srgb", willReadFrequently: true });
        let c = null;
        if (pixel) {
          pixel.canvas.width = 1;
          pixel.canvas.height = 1;
          pixel.clearRect(0, 0, 1, 1);
          pixel.fillStyle = "rgba(0, 0, 0, 0)";
          pixel.fillStyle = s;
          pixel.fillRect(0, 0, 1, 1);
          const d = pixel.getImageData(0, 0, 1, 1).data;
          // getImageData's values aren't premultiplied.
          c = [d[0] / 255, d[1] / 255, d[2] / 255, d[3] / 255];
        }
        if (converted.size > 64) converted.clear();
        converted.set(s, c);
        return c;
      };

      // Elements under a point, front to back, open shadow roots included (a host's own box comes
      // after what's drawn inside it).
      const stackAt = (x, y) => {
        const out = [], seen = new Set();
        for (const el of elementsFromPoint.call(document, x, y)) {
          if (seen.has(el)) continue;
          if (el.shadowRoot) {
            for (const inner of el.shadowRoot.elementsFromPoint(x, y)) {
              if (inner !== el && !seen.has(inner) && el.shadowRoot.contains(inner)) { seen.add(inner); out.push(inner); }
            }
          }
          seen.add(el);
          out.push(el);
        }
        return out;
      };

      // What's painted at a point, front to back, composited until opaque. Each element's own
      // background, under its ::before and ::after when they're positioned overlays (GitHub's header
      // paints its black on one, fading it in as the page scrolls). Undefined for a picture, a frame,
      // a background image or gradient, a blurred backdrop, or a color it can't read: the snapshot
      // decides those.
      const layers = (el) => {
        const out = [];
        for (const pseudo of ["::after", "::before"]) {
          const ps = getComputedStyle(el, pseudo);
          if (ps.content === "none" || ps.display === "none" || (ps.position !== "absolute" && ps.position !== "fixed")) continue;
          out.push([ps, Number(ps.opacity)]);
        }
        const style = getComputedStyle(el);
        out.push([style, 1]);
        return [out, Number(style.opacity)];
      };
      const at = (x, y) => {
        let r = 0, g = 0, b = 0, a = 0;
        for (const el of stackAt(x, y)) {
          if (pictures.has(el.tagName)) return undefined;
          const [stack, opacity] = layers(el);
          for (const [style, layerOpacity] of stack) {
            const visible = layerOpacity * opacity;
            if (!(visible > 0)) continue;
            if (style.backgroundImage !== "none") return undefined;
            const backdrop = style.backdropFilter || style.webkitBackdropFilter;
            if (backdrop && backdrop !== "none") return undefined;
            const c = parse(style.backgroundColor);
            if (!c) return undefined;
            const w = c[3] * visible * (1 - a);
            if (w <= 0) continue;
            r += c[0] * w; g += c[1] * w; b += c[2] * w; a += w;
            if (a > 0.995) return [r / a, g / a, b / a, 1];
          }
        }
        return a > 0 ? [r / a, g / a, b / a, a] : [0, 0, 0, 0];
      };

      const close = (p, q) => Math.abs(p[0] - q[0]) < 0.01 && Math.abs(p[1] - q[1]) < 0.01 &&
        Math.abs(p[2] - q[2]) < 0.01 && Math.abs(p[3] - q[3]) < 0.01;

      // Posts a change of color at the top. A baseline (when tracking starts) is only reported, not
      // shown: at rest the snapshot decides, and the estimate mustn't flash in ahead of it.
      const measure = (baseline) => {
        frame = 0;
        if (!active || window.scrollY < 0) return;
        const vv = window.visualViewport;
        const x0 = vv ? vv.offsetLeft : 0, width = vv ? vv.width : window.innerWidth;
        const y = (vv ? vv.offsetTop : 0) + 1;
        const points = [0.1, 0.3, 0.5, 0.7, 0.9].map((f) => at(x0 + width * f, y));
        // Four of the five points agreeing is the top's color; otherwise it's a mix.
        let color = null;
        for (const p of points) {
          if (p && points.filter((q) => q && close(p, q)).length >= 4) { color = p; break; }
        }
        const key = color ? color.map((v) => v.toFixed(3)).join() : "none";
        if (key === last && !baseline) return;
        // At most about 15 a second (a page's own color transition changes it every frame).
        const now = performance.now();
        if (!baseline && now - lastPost < 66) {
          if (!throttled) throttled = setTimeout(() => { throttled = 0; request(); }, 66 - (now - lastPost));
          return;
        }
        last = key;
        lastPost = now;
        handler.postMessage({ color, baseline }).catch(() => {});
      };
      const request = () => { if (active && !frame) frame = requestAnimationFrame(() => measure(false)); };

      const schedule = () => {
        if (!active) return;
        request();
        // Once more after the scrolling stops, for a header that changes color with a transition.
        trailing.forEach(clearTimeout);
        trailing = [150, 450].map((ms) => setTimeout(request, ms));
      };

      const ready = () => handler.postMessage({ ready: true }).then((on) => api.setActive(on), () => {});
      const api = {
        setActive(on) {
          active = on === true;
          last = "";
          if (active) requestAnimationFrame(() => measure(true));
        },
      };
      Object.defineProperty(window, "__cormorantPageTop", { value: api });
      addEventListener("scroll", schedule, { passive: true, capture: true });
      addEventListener("resize", schedule, { passive: true });
      document.addEventListener("transitionend", schedule, { passive: true, capture: true });
      // Back from the back/forward cache: whether to track may have changed meanwhile.
      addEventListener("pageshow", (event) => { if (event.persisted) ready(); });
      ready();
    })();
    """#
}
