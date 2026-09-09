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

  // Never prose, whatever they contain.
  var DROP = {
    SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, FORM: 1, INPUT: 1,
    BUTTON: 1, SELECT: 1, TEXTAREA: 1, NAV: 1, IFRAME: 1, OBJECT: 1,
    EMBED: 1, CANVAS: 1, MAP: 1, AREA: 1
  };

  function isBlank(s) { return !s || !/\S/.test(s); }

  // Collect the inline content of an element as styled runs.
  function runsOf(node, inherited) {
    var out = [];
    var style = inherited || { bold: false, italic: false, code: false, href: null };

    function push(text, s) {
      if (!text) return;
      var last = out[out.length - 1];
      if (last && last.bold === s.bold && last.italic === s.italic
          && last.code === s.code && last.href === s.href) {
        last.text += text;
        return;
      }
      out.push({ text: text, bold: s.bold, italic: s.italic, code: s.code, href: s.href });
    }

    function walk(n, s) {
      if (n.nodeType === 3) { push(n.nodeValue, s); return; }
      if (n.nodeType !== 1) return;
      var tag = n.tagName.toUpperCase();
      if (DROP[tag]) return;
      // A nested list is structure, not text. Walking into it welded its
      // items onto the parent's: "First itemNested oneNested two", with no
      // separator and no bullets. `emitList` recurses into them instead.
      if (tag === 'UL' || tag === 'OL') return;
      if (tag === 'BR') { push('\n', s); return; }

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
  function svgBlock(node, minSide) {
    var box = node.getAttribute('viewBox');
    var w = parseFloat(node.getAttribute('width')) || 0;
    var h = parseFloat(node.getAttribute('height')) || 0;
    if ((!w || !h) && box) {
      var parts = box.split(/[\s,]+/).map(parseFloat);
      if (parts.length === 4) { w = w || parts[2]; h = h || parts[3]; }
    }
    if (!w || !h) return null;
    if (Math.max(w, h) < minSide) return null;
    return { kind: 'svg', svg: node.outerHTML, width: w, height: h };
  }

  function imageBlock(node) {
    var src = node.getAttribute('src')
           || (node.getAttribute('srcset') || '').split(/\s|,/)[0];
    if (!src) return null;
    var w = parseFloat(node.getAttribute('width')) || 0;
    var h = parseFloat(node.getAttribute('height')) || 0;
    return { kind: 'image', src: src, width: w || null, height: h || null,
             caption: null, alt: node.getAttribute('alt') || null };
  }

  globalThis.__jdnBlocks = function (contentHTML, minSvgSide) {
    var doc = linkedom.parseHTML('<div id="jdn-root">' + contentHTML + '</div>').document;
    var root = doc.getElementById('jdn-root');
    var blocks = [];
    var dropped = {};

    function drop(tag) { dropped[tag] = (dropped[tag] || 0) + 1; }

    // Lists nest, and a flat list of runs cannot say so. Each item carries
    // its depth and its own ordered-ness, so the renderer can indent and
    // number correctly without knowing anything about HTML.
    function collectItems(node, ordered, depth, into) {
      var index = 0;
      for (var li = node.firstChild; li; li = li.nextSibling) {
        if (li.nodeType !== 1 || li.tagName.toUpperCase() !== 'LI') continue;
        index += 1;
        var r = runsOf(li);
        if (r.length) into.push({ runs: r, depth: depth, ordered: !!ordered, index: index });
        // Then whatever hangs below it.
        for (var c = li.firstChild; c; c = c.nextSibling) {
          if (c.nodeType !== 1) continue;
          var t = c.tagName.toUpperCase();
          if (t === 'UL') collectItems(c, false, depth + 1, into);
          else if (t === 'OL') collectItems(c, true, depth + 1, into);
        }
      }
    }

    function emitList(node, ordered) {
      var items = [];
      collectItems(node, ordered, 0, items);
      if (items.length) blocks.push({ kind: 'list', ordered: !!ordered, items: items });
    }

    function emitTable(node) {
      var rows = [];
      var trs = node.getElementsByTagName('tr');
      for (var i = 0; i < trs.length; i++) {
        var cells = [];
        for (var c = trs[i].firstChild; c; c = c.nextSibling) {
          if (c.nodeType !== 1) continue;
          var t = c.tagName.toUpperCase();
          if (t !== 'TD' && t !== 'TH') continue;
          cells.push(runsOf(c));
        }
        if (cells.length) rows.push(cells);
      }
      if (rows.length) blocks.push({ kind: 'table', rows: rows });
    }

    function emitFigure(node) {
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
          if (!isBlank(n.nodeValue)) {
            blocks.push({ kind: 'paragraph', runs: [{ text: n.nodeValue.replace(/\s+/g, ' ').trim(),
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
            var qr = runsOf(n);
            if (qr.length) blocks.push({ kind: 'quote', runs: qr });
            break;
          }
          case 'PRE': {
            var code = n.textContent || '';
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
            // A container: look inside. Anything that is only inline content
            // becomes a paragraph, so a <div>text</div> is not lost.
            var hasBlockChild = false;
            for (var c2 = n.firstChild; c2; c2 = c2.nextSibling) {
              if (c2.nodeType === 1 && /^(P|H[1-6]|UL|OL|BLOCKQUOTE|PRE|HR|FIGURE|TABLE|DIV|SECTION|ARTICLE|MAIN|HEADER|FOOTER|ASIDE|PICTURE|SVG|IMG)$/
                  .test(c2.tagName.toUpperCase())) { hasBlockChild = true; break; }
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
    return JSON.stringify({ blocks: blocks, dropped: dropped });
  };
})();
