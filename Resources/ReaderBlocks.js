// Turns Readability's HTML into a flat list of typed blocks.
//
// Runs in the same JSContext that already holds LinkeDOM and Readability, so
// the reader can be drawn natively with no web view involved. Extraction had
// already stopped needing WebKit; this is the other half.
//
// The output is deliberately flat and dull: a renderer should not have to
// understand HTML, and anything this file cannot classify is dropped rather
// than guessed at.
(function () {
  'use strict';

  // Inline emphasis worth carrying. Everything else inline contributes its
  // text and nothing more.
  var BOLD = { B: 1, STRONG: 1 };
  var ITALIC = { I: 1, EM: 1, CITE: 1 };
  var CODE = { CODE: 1, KBD: 1, SAMP: 1, TT: 1 };

  // Elements that flow inside a line of prose. Everything NOT here is treated
  // as a container to walk into.
  //
  // This used to be the other way round — an allow-list of block tags — and
  // that fails on the first container nobody thought of. cultofmac.com nests a
  // whole <html><body> INSIDE the article content, so the structure reads
  // SECTION > HTML > BODY > 63 paragraphs. `HTML` and `BODY` were not on the
  // block list, the section therefore looked as though it had no block
  // children, and all 9,893 characters came out as a single paragraph.
  //
  // An allow-list of containers has to be complete to be correct, and it never
  // will be. The inline set is small, closed and defined by HTML itself.
  var INLINE = {
    A: 1, ABBR: 1, B: 1, BDI: 1, BDO: 1, BR: 1, CITE: 1, CODE: 1, DATA: 1,
    DFN: 1, EM: 1, FONT: 1, I: 1, INS: 1, DEL: 1, KBD: 1, LABEL: 1, MARK: 1,
    Q: 1, RUBY: 1, S: 1, SAMP: 1, SMALL: 1, SPAN: 1, STRONG: 1, SUB: 1,
    SUP: 1, TIME: 1, TT: 1, U: 1, VAR: 1, WBR: 1, BIG: 1, STRIKE: 1
  };

  // Never prose, whatever they contain.
  var DROP = {
    SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, FORM: 1, INPUT: 1,
    BUTTON: 1, SELECT: 1, TEXTAREA: 1, NAV: 1, IFRAME: 1, OBJECT: 1,
    EMBED: 1, CANVAS: 1, MAP: 1, AREA: 1
  };

  function isBlank(s) { return !s || !/\S/.test(s); }

  // Collect the inline content of an element as styled runs.
  /// Elements that end a paragraph when they turn up inside a stretch of
  /// otherwise inline content — inside a list item or a table cell, say.
  var BLOCK_INSIDE_TEXT = {
    P: 1, DIV: 1, BLOCKQUOTE: 1, PRE: 1, FIGURE: 1, FIGCAPTION: 1,
    H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, SECTION: 1, ARTICLE: 1,
    HEADER: 1, FOOTER: 1, ASIDE: 1, DL: 1, DT: 1, DD: 1, HR: 1, TABLE: 1
  };
  var PARAGRAPH_MARK = '\u0001';

  // `budget` is optional and is shared: a table or a list passes one object
  // across all of its cells or items so the ceiling bounds the whole block,
  // not each part of it.
  function runsOf(node, inherited, budget) {
    var out = [];
    var style = inherited || { bold: false, italic: false, code: false, href: null };
    var left = budget || { chars: MAX_BLOCK_CHARS };

    function push(text, s) {
      if (!text) return;
      if (left.chars <= 0) { charsTruncated += text.length; return; }
      if (text.length > left.chars) { text = cutToLimit(text, left.chars); }
      left.chars -= text.length;
      var last = out[out.length - 1];
      if (last && last.bold === s.bold && last.italic === s.italic
          && last.code === s.code && last.href === s.href) {
        last.text += text;
        return;
      }
      out.push({ text: text, bold: s.bold, italic: s.italic, code: s.code, href: s.href });
    }

    function walk(n, s) {
      if (left.chars <= 0) return;
      if (n.nodeType === 3) { push(n.nodeValue, s); return; }
      if (n.nodeType !== 1) return;
      var tag = n.tagName.toUpperCase();
      if (DROP[tag]) return;
      // A nested list is structure, not text. Walking into it welded its
      // items onto the parent's: "First itemNested oneNested two", with no
      // separator and no bullets. `emitList` recurses into them instead.
      if (tag === 'UL' || tag === 'OL') return;
      if (tag === 'BR') { push('\n', s); return; }

      // A block boundary inside a run of inline text.
      //
      // Nothing used to be inserted here, so two paragraphs of one list item
      // came out welded: a Lobsters comment read "...nothing to do with it.I
      // don't agree with many of the points" — the end of one paragraph
      // against the start of the next, with no space and no break. Same
      // family as the bare <p> that welded standfirsts, and invisible in
      // exactly the same way, because it looks like the author's own bad
      // typing.
      //
      // Marked with U+0001 rather than a newline because the whitespace
      // collapse below is what HTML does and would eat a newline. A control
      // character cannot occur in real prose, so it survives the collapse and
      // is turned into a paragraph break afterwards.
      if (BLOCK_INSIDE_TEXT[tag] && out.length) push(PARAGRAPH_MARK, s);

      var next = {
        bold: s.bold || !!BOLD[tag],
        italic: s.italic || !!ITALIC[tag],
        code: s.code || !!CODE[tag],
        href: s.href
      };
      if (tag === 'A') {
        var href = n.getAttribute('href');
        if (href) next.href = href;
      }
      for (var c = n.firstChild; c; c = c.nextSibling) walk(c, next);
    }

    for (var c = node.firstChild; c; c = c.nextSibling) walk(c, style);

    // Collapse runs of whitespace, as HTML does, but keep the single spaces
    // that separate words across an inline boundary.
    for (var i = 0; i < out.length; i++) {
      out[i].text = out[i].text.replace(/\s+/g, ' ');
      // Now the marks can become real breaks, taking any space that collapsed
      // against them with them.
      out[i].text = out[i].text.replace(/ ?\u0001+ ?/g, '\n\n');
    }
    // Trim the very ends of the block only.
    if (out.length) {
      out[0].text = out[0].text.replace(/^\s+/, '');
      out[out.length - 1].text = out[out.length - 1].text.replace(/\s+$/, '');
    }
    return out.filter(function (r) { return r.text.length > 0; });
  }

  function textOf(runs) {
    return runs.map(function (r) { return r.text; }).join('');
  }

  // An <svg> is artwork or it is furniture, and the only honest discriminator
  // available is its size: not one of 135 inline SVGs on a real page carried
  // an aria-label or a <title> to say which it was. The threshold is supplied
  // by the caller so it can be tuned without editing this file.
  /// Longest SVG source that will be drawn, in characters.
  var MAX_SVG_SOURCE = 64 * 1024;

  /// Most blocks one article may produce. See the truncation at the end of
  /// this file.
  var MAX_BLOCKS = 4000;

  /// Most characters one block may carry, summed over every run it holds —
  /// and, for a table or a list, over every cell or item together.
  ///
  /// `MAX_BLOCKS` bounds how many blocks an article may produce and says
  /// nothing about what is inside one, so a single `<pre>` or a single
  /// `<p><a>` holding megabytes on one line walked straight past it. The cost
  /// is not the parse. Any run carrying a link is drawn by `ProseText`, whose
  /// `sizeThatFits` calls `NSLayoutManager.ensureLayout` synchronously on the
  /// main thread: measured at about 0.27 s per MB at a 700 pt container, and
  /// re-run on every size proposal, so continuously while a window is
  /// resized. 16 MB of single-paragraph text extracted inside the budget and
  /// then froze the main thread for about 4.4 s per layout pass, in a frame
  /// roughly 3.8 million points tall.
  var MAX_BLOCK_CHARS = 64 * 1024;

  /// Most parts — list items, or table cells — one block may hold. The
  /// character ceiling above bounds bulk, not count: 30,000 single-character
  /// `<li>` elements are one block, well under the character budget, and
  /// still 30,000 views drawn eagerly in a plain `VStack`.
  var MAX_BLOCK_PARTS = 2000;

  /// Longest image `src` that will be stored. Generous enough for a genuine
  /// inline `data:` image, and small enough that the per-pass percent-decode
  /// in `ReaderLede.key` cannot be handed a 30 MB string.
  var MAX_SRC_CHARS = 128 * 1024;

  /// Counts what the two ceilings above threw away, reported to the caller as
  /// part of `dropped`. Reset at the top of every `__jdnBlocks` call.
  var charsTruncated = 0;

  /// `text` cut to at most `limit` UTF-16 units, never between a surrogate
  /// pair.
  ///
  /// **A raw `slice` here cost the whole article, not one block.** The kept
  /// string could end on a lone high surrogate, `JSON.stringify` emitted it
  /// happily as `\ud83d`, and Swift's `JSONDecoder` then rejected the entire
  /// payload with "Missing low code point in surrogate pair" — so one emoji
  /// landing on the 65,536th unit turned a page that extracted perfectly into
  /// no article at all, and in the steady state (rung 1 locked after two wins)
  /// there was no WebKit rung left to fall through to.
  function cutToLimit(text, limit) {
    if (text.length <= limit) { return text; }
    var cut = limit;
    var last = text.charCodeAt(cut - 1);
    if (last >= 0xD800 && last <= 0xDBFF) { cut -= 1; }
    charsTruncated += text.length - cut;
    return text.slice(0, cut);
  }

  /// Largest side a declared SVG size may claim, in points. Far above any
  /// diagram and far below the point where a layout is asked for something
  /// impossible.
  var MAX_SVG_SIDE = 20000;

  // ── SVG sanitising ────────────────────────────────────────────────────────
  //
  // An inline SVG is drawn by `NSImage(data:)`, which yields AppKit's private
  // `_NSSVGImageRep`. That is closed Apple code, so what it will and will not
  // resolve is a property of the OS rather than of this app, and ImageIO
  // behaviour has changed under a major version before.
  //
  // Measured on macOS 26.6.2 on 2026-09-10, nothing external resolved: no
  // request from `<image xlink:href>`, `<image href>`, `<use href>`, CSS
  // `@import`, `url()`, `<script>` or `onload`, and no local file read via
  // `file://`. Zero requests reached a listener on 127.0.0.1.
  //
  // **That is one OS on one day, and the app supports macOS 14 upwards.**
  // Rather than re-measure every release, the constructs are removed here so
  // the OS's behaviour stops mattering. `tools/svg-capability-probe.swift`
  // stays as a regression check, not as the defence.
  //
  // Kept deliberately: fragment references (`#id`) and `data:` URIs. `<use
  // href="#icon">` is how half of real diagrams are built and a data: image is
  // self-contained, already covered by the source-size ceiling.

  /// Elements removed whole. Each can carry or execute something that is not
  /// drawing: `foreignObject` can hold arbitrary HTML including an iframe.
  var SVG_DROP_ELEMENTS = /^(script|foreignobject|iframe|object|embed|audio|video|link|meta|base)$/i;

  /// A reference that stays inside this document.
  function svgRefIsLocal(value) {
    var v = String(value || '').trim();
    if (!v) return true;
    return v.charAt(0) === '#' || /^data:/i.test(v);
  }

  /// True when a CSS fragment reaches outside the document.
  function svgCSSReachesOut(css) {
    var text = String(css || '');
    if (/@import/i.test(text)) return true;
    var m = text.match(/url\(\s*['"]?([^'")]*)/gi) || [];
    for (var i = 0; i < m.length; i++) {
      var ref = m[i].replace(/^url\(\s*['"]?/i, '');
      if (!svgRefIsLocal(ref)) return true;
    }
    return false;
  }

  /// Strips every way an SVG could reach outside itself, on a COPY, so the
  /// live DOM the walker is still reading is untouched.
  function sanitiseSVG(node) {
    var root = node.cloneNode(true);
    var all = [root].concat(Array.prototype.slice.call(root.querySelectorAll('*')));
    for (var i = all.length - 1; i >= 0; i--) {
      var el = all[i];
      // The LOCAL name. `tagName` keeps any namespace prefix, so `<svg:script>`
      // matched nothing and survived verbatim into the emitted block — which
      // made the claim above, that removing these makes the OS's behaviour stop
      // mattering, false as written.
      var qualified = (el.tagName || '').toLowerCase();
      var tag = qualified.indexOf(':') >= 0 ? qualified.split(':').pop() : qualified;
      if (el !== root && SVG_DROP_ELEMENTS.test(tag)) {
        if (el.parentNode) { el.parentNode.removeChild(el); }
        continue;
      }
      if (tag === 'style' && svgCSSReachesOut(el.textContent)) {
        if (el.parentNode) { el.parentNode.removeChild(el); }
        continue;
      }
      // Copy the names first: removing while iterating skips attributes.
      var names = [];
      var attrs = el.attributes || [];
      for (var a = 0; a < attrs.length; a++) { names.push(attrs[a].name); }
      for (var n = 0; n < names.length; n++) {
        var name = names[n];
        var lower = name.toLowerCase();
        var value = el.getAttribute(name);
        // Event handlers: onload, onclick, onbegin, and the rest.
        if (lower.indexOf('on') === 0) { el.removeAttribute(name); continue; }
        // href in any namespace.
        if (lower === 'href' || lower === 'xlink:href' || lower === 'src') {
          if (!svgRefIsLocal(value)) { el.removeAttribute(name); }
          continue;
        }
        // `style`, and the presentation attributes that take url(): fill,
        // stroke, filter, mask, clip-path, marker-start and friends.
        if (svgCSSReachesOut(value)) { el.removeAttribute(name); }
      }
    }
    return root.outerHTML;
  }

  function svgBlock(node, minSide) {
    var box = node.getAttribute('viewBox');
    var w = parseFloat(node.getAttribute('width')) || 0;
    var h = parseFloat(node.getAttribute('height')) || 0;
    if ((!w || !h) && box) {
      var parts = box.split(/[\s,]+/).map(parseFloat);
      if (parts.length === 4) { w = w || parts[2]; h = h || parts[3]; }
    }
    if (!w || !h) return null;
    // A size is a number the page chooses. `width="0.0000001" height="1e308"`
    // is a hundred bytes of markup that reaches the reader's layout as
    // infinity. Finite, positive, and no larger than any real diagram.
    if (!isFinite(w) || !isFinite(h) || w <= 0 || h <= 0) return null;
    if (w > MAX_SVG_SIDE || h > MAX_SVG_SIDE) return null;
    if (Math.max(w, h) < minSide) return null;
    // An SVG is source code that AppKit will execute as drawing instructions,
    // and the size of the source is the only cheap proxy for how much work it
    // asks for. Measured on the exact bytes this pipeline produced: 240.1 KB
    // carrying a few hundred filter primitives took **31.05 seconds to draw
    // and 1,680 MB of resident memory**, and painted nothing at all. A real
    // diagram is a few KB.
    var source = sanitiseSVG(node);
    if (source.length > MAX_SVG_SOURCE) { return null; }
    return { kind: 'svg', svg: source, width: w, height: h };
  }

  function imageBlock(node) {
    var src = node.getAttribute('src')
           || (node.getAttribute('srcset') || '').split(/\s|,/)[0];
    if (!src) return null;
    if (src.length > MAX_SRC_CHARS) return null;
    var w = parseFloat(node.getAttribute('width')) || 0;
    var h = parseFloat(node.getAttribute('height')) || 0;
    return { kind: 'image', src: src, width: w || null, height: h || null,
             caption: null, alt: node.getAttribute('alt') || null };
  }

  // Elements that may legitimately sit in <head>. Everything else ends it.
  var HEAD_ONLY = {
    BASE: 1, BASEFONT: 1, BGSOUND: 1, LINK: 1, META: 1,
    NOSCRIPT: 1, SCRIPT: 1, STYLE: 1, TEMPLATE: 1, TITLE: 1
  };

  // Put back the <body> a spec parser would have opened.
  //
  // LinkeDOM parses with htmlparser2, which is not an HTML tree builder: it
  // nests what it is given. The spec says the "in head" insertion mode ends
  // the moment a token appears that cannot be in <head>, at which point the
  // parser pops <head>, moves to "in body", and everything after belongs to
  // the body. htmlparser2 keeps nesting inside <head> instead.
  //
  // qip.dev serves `<!doctype html><html><head>` with **no </head> and no
  // <body> anywhere**, which is legal HTML. So its <main> landed inside
  // <head>, the ancestor chain from any paragraph read
  // P -> MAIN -> HEAD -> HTML -> #document and never met BODY, and
  // Readability's `while (parentOfTopCandidate.tagName !== "BODY")` walked
  // off the top of the tree and threw on null. The whole article was lost to
  // a missing closing tag.
  //
  // Returns how many nodes it moved, so the log can say when it acted.
  function repairHeadBody(doc) {
    var head = doc.head, body = doc.body;
    if (!head || !body) return 0;

    var first = null;
    for (var n = head.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 1 && !HEAD_ONLY[n.tagName.toUpperCase()]) { first = n; break; }
    }
    if (!first) return 0;

    // Collect before moving: `insertBefore` detaches, which would break a
    // walk that reads `nextSibling` as it goes.
    var moving = [], node = first;
    while (node) { moving.push(node); node = node.nextSibling; }

    // Prepended in order, so anything the parser did manage to put in the
    // body still follows the content that preceded it in the source.
    var anchor = body.firstChild;
    for (var i = 0; i < moving.length; i++) body.insertBefore(moving[i], anchor);
    return moving.length;
  }

  globalThis.__jdnRepairTree = repairHeadBody;

  globalThis.__jdnBlocks = function (contentHTML, minSvgSide) {
    var doc = linkedom.parseHTML('<div id="jdn-root">' + contentHTML + '</div>').document;
    var root = doc.getElementById('jdn-root');
    var blocks = [];
    var dropped = {};
    charsTruncated = 0;

    function drop(tag) { dropped[tag] = (dropped[tag] || 0) + 1; }

    // Lists nest, and a flat list of runs cannot say so. Each item carries
    // its depth and its own ordered-ness, so the renderer can indent and
    // number correctly without knowing anything about HTML.
    function collectItems(node, ordered, depth, into, budget) {
      var index = 0;
      for (var li = node.firstChild; li; li = li.nextSibling) {
        if (li.nodeType !== 1 || li.tagName.toUpperCase() !== 'LI') continue;
        if (into.length >= MAX_BLOCK_PARTS) return;
        index += 1;
        var r = runsOf(li, null, budget);
        if (r.length) into.push({ runs: r, depth: depth, ordered: !!ordered, index: index });
        // Then whatever hangs below it.
        for (var c = li.firstChild; c; c = c.nextSibling) {
          if (c.nodeType !== 1) continue;
          var t = c.tagName.toUpperCase();
          if (t === 'UL') collectItems(c, false, depth + 1, into, budget);
          else if (t === 'OL') collectItems(c, true, depth + 1, into, budget);
        }
      }
    }

    /// Whether this list's items are sections of an article rather than
    /// entries in a list.
    ///
    /// A heading inside an `<li>` is the signal, and it is close to
    /// unambiguous: a real bulleted list does not have `<h2>` in it, and an
    /// article broken into numbered parts almost always does. Deliberately NOT
    /// keyed on several `<p>` per item — a Lobsters comment is several
    /// paragraphs in one `<li>` and is genuinely a list entry, which
    /// `runsOf`'s paragraph marks already handle.
    ///
    /// Same bound and the same safe direction as `figureHoldsProse`.
    function listHoldsSections(node) {
      var stack = [];
      for (var c = node.firstChild; c; c = c.nextSibling) stack.push(c);
      var seen = 0;
      while (stack.length) {
        var n = stack.pop();
        // **A list too big to classify is still a list.** The opposite answer
        // is right for a figure, where walking as a container costs only the
        // caption pairing; here it costs the list. `seen` counts every node,
        // so 2,000 bare `<li>` — or 1,000 that each wrap a `<span>` — tripped
        // it with nothing hostile involved, and every bullet and number went,
        // leaving a changelog or an index reading as undifferentiated prose.
        if (++seen > LIST_SCAN_LIMIT) return false;
        if (n.nodeType !== 1) continue;
        var tag = n.tagName.toUpperCase();
        if (HEADING[tag]) return true;
        for (var k = n.firstChild; k; k = k.nextSibling) stack.push(k);
      }
      return false;
    }

    /// A list, or an article that happens to be numbered.
    ///
    /// **The Guardian writes a whole "Key Takeaways" piece as
    /// `<ol><li><h2>…</h2><p>…</p><p>…</p></li>`**, seven items, forty-two
    /// paragraphs. Flattened into list items that arrived as one block of
    /// welded text with every heading gone, and `runsOf` would then have spent
    /// one shared character budget across the lot. Walked as a container, the
    /// headings are headings and the paragraphs are paragraphs — and the
    /// numbering survives, because the page writes it into the heading itself
    /// as `<span>1. </span>`.
    function emitList(node, ordered) {
      if (listHoldsSections(node)) { walk(node); return; }
      return emitPlainList(node, ordered);
    }

    function emitPlainList(node, ordered) {
      var items = [];
      // One budget for the whole list, so its ceiling is a property of the
      // block rather than of each item.
      collectItems(node, ordered, 0, items, { chars: MAX_BLOCK_CHARS });
      if (items.length >= MAX_BLOCK_PARTS) drop('list-items');
      if (items.length) blocks.push({ kind: 'list', ordered: !!ordered, items: items });
    }

    function emitTable(node) {
      var rows = [];
      var budget = { chars: MAX_BLOCK_CHARS };
      var parts = 0;
      var trs = node.getElementsByTagName('tr');
      var i = 0;
      for (; i < trs.length && parts < MAX_BLOCK_PARTS; i++) {
        var cells = [];
        for (var c = trs[i].firstChild; c && parts < MAX_BLOCK_PARTS; c = c.nextSibling) {
          if (c.nodeType !== 1) continue;
          var t = c.tagName.toUpperCase();
          if (t !== 'TD' && t !== 'TH') continue;
          cells.push(runsOf(c, null, budget));
          parts += 1;
        }
        if (cells.length) rows.push(cells);
      }
      if (i < trs.length) drop('table-rows');
      if (rows.length) blocks.push({ kind: 'table', rows: rows });
    }

    var HEADING = { H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1 };

    /// Elements that mean a `<figure>` is holding an article, not a picture.
    ///
    /// **`P` is deliberately not in this set.** Ars Technica writes an ordinary
    /// photograph as `<figure><div><p><a><img>`, and counting that `<p>` as
    /// prose walked the figure as a container: its caption came out as two
    /// paragraphs and a "Credit:" line, each of them twice over. A paragraph
    /// inside a figure is picture furniture. A list, a table, a heading or a
    /// section is not.
    /// Headings are not in the set either, for the same reason. A figure of
    /// `<h2>Chart 1</h2><img><figcaption>` is a chart, and counting the
    /// heading as prose unpaired the caption from the picture. The shapes that
    /// really do carry an article all bring a container with them.
    var FIGURE_PROSE = {
      OL: 1, UL: 1, DL: 1, TABLE: 1, BLOCKQUOTE: 1, PRE: 1,
      SECTION: 1, ARTICLE: 1
    };

    /// Most nodes looked at before a `<figure>` is called a container anyway.
    ///
    /// Bounds the scan, and errs the safe way: a figure too big to classify in
    /// this many nodes is not a picture, and walking it as a container loses
    /// nothing but the caption pairing. Answering `false` here instead would
    /// hand a page a way to hide its own prose behind a few thousand empty
    /// spans.
    var FIGURE_SCAN_LIMIT = 2000;

    /// The same for a list, and far higher, because exhausting it answers
    /// "ordinary list" rather than "container": a long reference list is a
    /// real shape, and the cost of scanning one is linear and paid once.
    var LIST_SCAN_LIMIT = 200000;

    /// Whether this `<figure>` carries prose of its own, outside its caption.
    ///
    /// Short-circuits on the first one found, so an ordinary picture figure
    /// costs a handful of node visits.
    function figureHoldsProse(node) {
      var stack = [];
      for (var c = node.firstChild; c; c = c.nextSibling) stack.push(c);
      var seen = 0;
      while (stack.length) {
        var n = stack.pop();
        if (++seen > FIGURE_SCAN_LIMIT) return true;
        if (n.nodeType !== 1) continue;
        var tag = n.tagName.toUpperCase();
        // Its contents are the caption, and a caption may be a <p>.
        if (tag === 'FIGCAPTION') continue;
        // A gallery is picture furniture too. `<figure><ul><li><img>` is what
        // several CMSs emit, and routing it to the container path lost the
        // pictures outright: `collectItems` only ever calls `runsOf`, which
        // has no IMG case, so every `<img>` inside an `<li>` contributed
        // nothing and was discarded without even a `drop()`.
        if ((tag === 'UL' || tag === 'OL') && isPictureList(n)) continue;
        if (FIGURE_PROSE[tag]) return true;
        for (var k = n.firstChild; k; k = k.nextSibling) stack.push(k);
      }
      return false;
    }

    /// A list whose items are pictures and nothing else worth reading.
    function isPictureList(node) {
      var images = node.getElementsByTagName('img').length
                 + node.getElementsByTagName('picture').length;
      if (!images) return false;
      for (var t in HEADING) {
        if (node.getElementsByTagName(t.toLowerCase()).length) return false;
      }
      return !/\S/.test(node.textContent || '');
    }

    /// A `<figure>`: a picture with a caption, or, sometimes, a whole article.
    ///
    /// **This used to assume the first of those.** `getElementsByTagName` looks
    /// at every descendant, so a figure wrapping an article found the one
    /// picture nested somewhere inside it, emitted that, and returned — taking
    /// the rest with it, silently, with nothing recorded in `dropped`.
    ///
    /// The Guardian's "Key Takeaways" articles are exactly that shape:
    /// `<figure data-spacefinder-type="…KeyTakeawaysBlockElement"><ol><li>`
    /// holding every heading and paragraph in the piece. One such article
    /// extracted 13,791 characters of text and rendered as a single
    /// photograph.
    ///
    /// So a figure carrying prose is walked as a container, which emits its
    /// pictures and its prose in document order through the ordinary cases.
    /// The only thing that costs is pairing a `<figcaption>` with the picture,
    /// and a figure holding an article was never that pairing.
    function emitFigure(node) {
      if (figureHoldsProse(node)) { walk(node); return; }
      var img = node.getElementsByTagName('img')[0];
      var svgs = node.getElementsByTagName('svg');
      var caption = null;
      var cap = node.getElementsByTagName('figcaption')[0];
      if (cap) { var r = runsOf(cap); if (r.length) caption = r; }
      if (img) {
        var b = imageBlock(img);
        if (b) { b.caption = caption; blocks.push(b); return; }
      }
      if (svgs.length) {
        var sb = svgBlock(svgs[0], minSvgSide);
        if (sb) { sb.caption = caption; blocks.push(sb); return; }
        drop('svg');
        return;
      }
      // A figure with no picture is just its caption, if it has one.
      if (caption) blocks.push({ kind: 'paragraph', runs: caption });
    }

    function walk(node) {
      for (var n = node.firstChild; n; n = n.nextSibling) {
        if (n.nodeType === 3) {
          // Loose text between blocks. Real on some feeds.
          //
          // **The one `blocks.push` that used to bypass the budget.** Every
          // other emitter routes its text through `runsOf`, or cuts it
          // explicitly as the `<pre>` case does; this arm took `nodeValue`
          // verbatim. A bare text node is not an element, so neither the
          // 60,000-element ceiling nor the depth guard can see it either:
          // `<article><p>a</p>` + 300,000 characters + `<p>b</p>` emitted a
          // 300,000-character block with `dropped` empty, while the same bulk
          // inside a `<p>` was cut to 65,536.
          if (!isBlank(n.nodeValue)) {
            var loose = cutToLimit(n.nodeValue.replace(/\s+/g, ' ').trim(), MAX_BLOCK_CHARS);
            blocks.push({ kind: 'paragraph', runs: [{ text: loose,
                                                      bold: false, italic: false, code: false, href: null }] });
          }
          continue;
        }
        if (n.nodeType !== 1) continue;
        var tag = n.tagName.toUpperCase();

        if (DROP[tag]) { drop(tag.toLowerCase()); continue; }

        switch (tag) {
          case 'P': {
            var r = runsOf(n);
            if (r.length && !isBlank(textOf(r))) blocks.push({ kind: 'paragraph', runs: r });
            // A paragraph can be a wrapper round nothing but an image.
            var imgs = n.getElementsByTagName('img');
            for (var i = 0; i < imgs.length; i++) {
              var ib = imageBlock(imgs[i]);
              if (ib) blocks.push(ib);
            }
            break;
          }
          case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': {
            var hr = runsOf(n);
            if (hr.length) blocks.push({ kind: 'heading', level: parseInt(tag[1], 10), runs: hr });
            break;
          }
          case 'UL': emitList(n, false); break;
          case 'OL': emitList(n, true); break;
          case 'BLOCKQUOTE': {
            // Text first, then any pictures inside it.
            //
            // A quote used to be text and nothing else, so **every image
            // inside a blockquote was silently lost**. thedailywtf.com puts
            // each of its screenshots in
            // `<blockquote><p><a href="#id"><img></a></p></blockquote>`, which
            // is the whole point of the article, and the reader showed the
            // captions with no pictures. Found by Jonathan comparing the
            // reader against Safari.
            //
            // Emitted after the quote rather than in document order, because a
            // quote's text is its own block and splitting it around a picture
            // would read worse than following it.
            var qr = runsOf(n);
            if (qr.length) blocks.push({ kind: 'quote', runs: qr });
            var quoted = n.querySelectorAll ? n.querySelectorAll('img') : [];
            for (var qi = 0; qi < quoted.length; qi++) {
              var qb = imageBlock(quoted[qi]);
              if (qb) { blocks.push(qb); }
            }
            break;
          }
          case 'PRE': {
            // One <pre> is one element, so MAX_BLOCKS never saw it. This is
            // the cleanest way to hand the layout engine a megabyte on one
            // line, and so the one that has to be clamped here.
            var code = cutToLimit(n.textContent || '', MAX_BLOCK_CHARS);
            if (!isBlank(code)) blocks.push({ kind: 'code', text: code.replace(/\s+$/, '') });
            break;
          }
          case 'HR': blocks.push({ kind: 'rule' }); break;
          case 'IMG': { var b1 = imageBlock(n); if (b1) blocks.push(b1); break; }
          case 'PICTURE': {
            var pimg = n.getElementsByTagName('img')[0];
            var b2 = pimg && imageBlock(pimg);
            if (b2) blocks.push(b2); else drop('picture');
            break;
          }
          case 'SVG': {
            var sb2 = svgBlock(n, minSvgSide);
            if (sb2) blocks.push(sb2); else drop('svg');
            break;
          }
          case 'FIGURE': emitFigure(n); break;
          case 'TABLE': emitTable(n); break;
          case 'TIME': drop('time'); break;
          default:
            // A container: look inside. Anything holding only inline content
            // becomes a paragraph, so a <div>text</div> is not lost.
            var hasBlockChild = false;
            for (var c2 = n.firstChild; c2; c2 = c2.nextSibling) {
              if (c2.nodeType === 1 && !INLINE[c2.tagName.toUpperCase()]) {
                hasBlockChild = true;
                break;
              }
            }
            if (hasBlockChild) { walk(n); }
            else {
              var dr = runsOf(n);
              if (dr.length && !isBlank(textOf(dr))) blocks.push({ kind: 'paragraph', runs: dr });
            }
        }
      }
    }

    walk(root);
    // A ceiling on the block count, for the same reason there is one on SVG
    // source: the work is proportional to a number the page chooses. Each
    // block carrying a link becomes an NSTextView whose layout is forced
    // synchronously, and a page of 40,000 short linked paragraphs — 3.66 MB,
    // well inside the fetch ceiling — walks in under seven seconds and then
    // asks the reader to lay all of them out in one pass.
    //
    // 4,000 is far above any real article: the longest this pipeline has
    // produced from a live page is 563.
    if (blocks.length > MAX_BLOCKS) {
      dropped['over-block-limit'] = blocks.length - MAX_BLOCKS;
      blocks = blocks.slice(0, MAX_BLOCKS);
    }
    if (charsTruncated > 0) dropped['over-block-chars'] = charsTruncated;
    return JSON.stringify({ blocks: blocks, dropped: dropped });
  };
})();
