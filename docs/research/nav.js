(function () {
  var pages = [
    ["index.html", "Overview"],
    ["landscape.html", "Landscape"],
    ["how-they-did-it.html", "How they did it"],
    ["delivery.html", "Delivery"],
    ["stack.html", "What we pick"]
  ];
  var here = location.pathname.split("/").pop() || "index.html";
  var i = pages.findIndex(function (p) { return p[0] === here; });
  var nav = document.createElement("nav");
  nav.className = "site-nav";
  nav.setAttribute("aria-label", "Showtell pages");
  nav.innerHTML = '<div class="inner"><a class="brand" href="index.html">Show<span>tell</span></a><ul>' +
    pages.map(function (p, n) {
      return '<li><a class="tab" href="' + p[0] + '"' + (n === i ? ' aria-current="page"' : '') +
        '><span class="num">' + (n + 1) + '</span>' + p[1] + '</a></li>';
    }).join("") + "</ul></div>";
  document.body.prepend(nav);
  var slot = document.getElementById("pager");
  if (slot && i >= 0) {
    var prev = pages[i - 1], next = pages[i + 1];
    slot.className = "pager";
    slot.innerHTML =
      (prev ? '<a href="' + prev[0] + '"><div class="lbl">← Previous</div><div class="ttl">' + prev[1] + '</div></a>' : '') +
      (next ? '<a class="next" href="' + next[0] + '"><div class="lbl">Next →</div><div class="ttl">' + next[1] + '</div></a>' : '');
  }
})();
