/* Local File Diet — site behaviour.
   No dependencies, no third-party requests, no analytics. */
(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ------------------------------------------------------------ year */
  var year = String(new Date().getFullYear());
  document.querySelectorAll("[data-year]").forEach(function (n) {
    n.textContent = year;
  });

  /* ------------------------------------------------- current nav item */
  var here = window.location.pathname.split("/").pop() || "index.html";
  document.querySelectorAll(".nav a").forEach(function (a) {
    var href = (a.getAttribute("href") || "").split("/").pop();
    if (href === here) a.setAttribute("aria-current", "page");
  });

  /* --------------------------------- header CTA + mobile dock reveal */
  var trigger = document.querySelector("[data-scroll-trigger]");
  if (trigger && "IntersectionObserver" in window) {
    new IntersectionObserver(
      function (entries) {
        document.body.dataset.scrolled = String(!entries[0].isIntersecting);
      },
      { rootMargin: "-40px 0px 0px 0px" }
    ).observe(trigger);
  } else {
    document.body.dataset.scrolled = "true";
  }

  /* ------------------------------------------------- scroll reveals */
  var revealables = document.querySelectorAll(".rv");
  if (revealables.length) {
    if (reduceMotion || !("IntersectionObserver" in window)) {
      revealables.forEach(function (n) { n.classList.add("in"); });
    } else {
      var revealObserver = new IntersectionObserver(
        function (entries, obs) {
          entries.forEach(function (e) {
            if (!e.isIntersecting) return;
            e.target.classList.add("in");
            obs.unobserve(e.target);
          });
        },
        { rootMargin: "0px 0px -12% 0px", threshold: 0.08 }
      );
      revealables.forEach(function (n) { revealObserver.observe(n); });
    }
  }

  /* ------------------------------------------------- legal page TOC */
  var tocLinks = document.querySelectorAll(".toc a");
  if (tocLinks.length && "IntersectionObserver" in window) {
    var byId = {};
    tocLinks.forEach(function (a) {
      byId[(a.getAttribute("href") || "").replace("#", "")] = a;
    });
    var headings = document.querySelectorAll(".doc-sec h2[id]");
    var spy = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          tocLinks.forEach(function (a) { a.removeAttribute("aria-current"); });
          var link = byId[e.target.id];
          if (link) link.setAttribute("aria-current", "true");
        });
      },
      { rootMargin: "-90px 0px -72% 0px" }
    );
    headings.forEach(function (h) { spy.observe(h); });
  }

  /* ==================================================================
     The instrument — illustrative target/result model.
     Values are MODELLED, not measured benchmarks. The efficiency
     figures express the product claim "lands within ~4% of target in a
     single pass"; they are not results from any one specific file.
     ================================================================== */
  var rig = document.querySelector("[data-instrument]");
  if (!rig) return;

  var PROFILES = {
    video: { original: 112.4, floor: 2,   start: 10, efficiency: 0.962 },
    pdf:   { original: 48.6,  floor: 0.5, start: 5,  efficiency: 0.945 },
    image: { original: 14.2,  floor: 0.2, start: 2,  efficiency: 0.974 }
  };

  var STEPS = 240; // slider resolution; target derived logarithmically

  var el = {
    seg:       rig.querySelector("[data-seg]"),
    slider:    rig.querySelector("[data-slider]"),
    sliderVal: rig.querySelector("[data-slider-val]"),
    original:  rig.querySelector("[data-out-original]"),
    target:    rig.querySelector("[data-out-target]"),
    result:    rig.querySelector("[data-out-result]"),
    delta:     rig.querySelector("[data-out-delta]"),
    fill:      rig.querySelector("[data-scale-fill]"),
    band:      rig.querySelector("[data-detail-band]"),
    marker:    rig.querySelector("[data-detail-result]"),
    legendMax: rig.querySelector("[data-legend-max]"),
    detailLo:  rig.querySelector("[data-detail-lo]"),
    detailHi:  rig.querySelector("[data-detail-hi]"),
    zoom:      rig.querySelector("[data-zoom]"),
    verdict:   rig.querySelector("[data-verdict]"),
    ticks:     rig.querySelector("[data-ticks]")
  };

  /* the magnified track spans 80%–105% of the chosen target, so the
     ≈4% landing window occupies a legible 16% of its width */
  var DETAIL_LO = 0.80;
  var DETAIL_HI = 1.05;

  var kind = "video";
  var shown = { target: 0, result: 0, delta: 0 };

  if (el.ticks && !el.ticks.children.length) {
    var frag = document.createDocumentFragment();
    for (var t = 0; t < 41; t++) frag.appendChild(document.createElement("i"));
    el.ticks.appendChild(frag);
  }

  function fmt(mb) {
    if (mb < 1) return (mb * 1024).toFixed(0) + " KB";
    return mb.toFixed(mb < 10 ? 2 : 1) + " MB";
  }

  /* people ask for round limits ("under 10 MB"), so snap to them */
  function snap(mb) {
    if (mb < 1) return Math.round(mb * 1024 / 50) * 50 / 1024;
    if (mb < 10) return Math.round(mb * 10) / 10;
    if (mb < 50) return Math.round(mb * 2) / 2;
    return Math.round(mb);
  }

  /* logarithmic slider so small targets keep usable precision */
  function positionToTarget(pos) {
    var p = PROFILES[kind];
    var lo = Math.log(p.floor);
    var hi = Math.log(p.original);
    return snap(Math.exp(lo + (hi - lo) * (pos / STEPS)));
  }

  function targetToPosition(mb) {
    var p = PROFILES[kind];
    var lo = Math.log(p.floor);
    var hi = Math.log(p.original);
    return Math.round(((Math.log(mb) - lo) / (hi - lo)) * STEPS);
  }

  function animate(node, key, to, render) {
    var from = shown[key];
    shown[key] = to;
    if (reduceMotion || from === to) {
      node.textContent = render(to);
      return;
    }
    var start = performance.now();
    var dur = 420;
    (function tick(now) {
      var k = Math.min(1, (now - start) / dur);
      var eased = 1 - Math.pow(1 - k, 3);
      node.textContent = render(from + (to - from) * eased);
      if (k < 1) requestAnimationFrame(tick);
    })(start);
  }

  function draw() {
    var p = PROFILES[kind];
    var target = positionToTarget(Number(el.slider.value));
    var atCeiling = target >= p.original * 0.995;
    var result = atCeiling ? p.original : target * p.efficiency;
    var delta = (1 - result / p.original) * 100;

    el.original.textContent = fmt(p.original);
    el.legendMax.textContent = fmt(p.original);
    el.sliderVal.textContent = fmt(target);
    el.slider.setAttribute("aria-valuetext", fmt(target));

    animate(el.target, "target", target, fmt);
    animate(el.result, "result", result, fmt);
    animate(el.delta, "delta", delta, function (v) {
      return (v <= 0.05 ? "0" : "−" + v.toFixed(1)) + "%";
    });

    /* coarse bar: how much of the original is left */
    el.fill.style.width = ((result / p.original) * 100).toFixed(2) + "%";

    /* magnified bar: where the result lands relative to the limit */
    var span = DETAIL_HI - DETAIL_LO;
    var resultPos = Math.max(0, ((result / target) - DETAIL_LO) / span * 100);
    var limitPos = (1 - DETAIL_LO) / span * 100; /* 80% */

    el.marker.style.left = resultPos.toFixed(2) + "%";
    el.band.style.left = resultPos.toFixed(2) + "%";
    el.band.style.width = Math.max(0, limitPos - resultPos).toFixed(2) + "%";

    el.detailLo.textContent = fmt(target * DETAIL_LO);
    el.detailHi.textContent = fmt(target * DETAIL_HI);
    el.zoom.textContent = "×" + Math.max(1, Math.round(p.original / (span * target)));

    /* message templates live in the markup so each locale ships its own */
    if (atCeiling) {
      el.verdict.dataset.state = "over";
      el.verdict.textContent = rig.dataset.msgOver;
    } else {
      el.verdict.dataset.state = "ok";
      el.verdict.textContent = rig.dataset.msgOk
        .replace("{result}", fmt(result))
        .replace("{target}", fmt(target));
    }
  }

  el.seg.addEventListener("click", function (e) {
    var btn = e.target.closest("button[data-kind]");
    if (!btn) return;
    kind = btn.dataset.kind;
    el.seg.querySelectorAll("button").forEach(function (b) {
      b.setAttribute("aria-checked", String(b === btn));
      b.setAttribute("tabindex", b === btn ? "0" : "-1");
    });
    el.slider.value = String(targetToPosition(PROFILES[kind].start));
    draw();
  });

  el.seg.addEventListener("keydown", function (e) {
    if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
    var btns = Array.prototype.slice.call(el.seg.querySelectorAll("button"));
    var i = btns.indexOf(document.activeElement);
    if (i < 0) return;
    e.preventDefault();
    var next = btns[(i + (e.key === "ArrowRight" ? 1 : btns.length - 1)) % btns.length];
    next.focus();
    next.click();
  });

  el.slider.addEventListener("input", draw);

  el.slider.max = String(STEPS);
  el.slider.value = String(targetToPosition(PROFILES[kind].start));
  draw();
})();
