/* Token 用量 — dashboard front end (stdlib + vendored ECharts, no CDN). */
(function () {
  "use strict";

  var STORAGE_KEY = "tokenboard.ui";
  var METRIC_LABELS = {
    total: "总处理量（含 cache）",
    io: "输入+输出",
    input: "仅输入",
    output: "仅输出",
    cost: "成本 (USD)"
  };
  var RANGE_LABELS = {
    today: "今日",
    yesterday: "昨日",
    "3": "近3日",
    "7": "近7日",
    "30": "近30日",
    custom: "自定义"
  };
  var SOURCE_COLORS = {
    pi: "#B08F45",
    "claude-code": "#C2714F",
    codex: "#7468CC",
    workbuddy: "#2E9E76"
  };
  // Vendored brand marks (static/logos/, see its README for sources/licences).
  // Used for the Coding Agent tab only; other tabs keep the plain dot.
  var SOURCE_LOGOS = {
    pi: "/static/logos/pi.svg",
    "claude-code": "/static/logos/claude-code.svg",
    codex: "/static/logos/codex.svg",
    workbuddy: "/static/logos/workbuddy.svg"
  };
  var PALETTE = [
    "#7468CC", "#B08F45", "#2E9E76", "#c58af9",
    "#f97583", "#63d3d8", "#a6e3a1", "#f2cc60"
  ];
  var TOP_ROWS = 20;
  var ACCENT_COLOR = "#6EA8FE";

  var state = {
    range: "30",
    start: "",
    end: "",
    metric: "total",
    tab: "source",
    expanded: false
  };
  var chart = null;
  var cached = { days: [], series: {}, rows: [] };
  // Monotonic generation: only the newest refresh may touch the DOM, so a slow
  // response can never overwrite a newer one.
  var requestGen = 0;

  /* ---------- persistence (best effort) ---------- */
  function loadState() {
    try {
      var raw = window.localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      var saved = JSON.parse(raw);
      if (saved && typeof saved === "object") {
        if (saved.range) state.range = String(saved.range);
        if (saved.metric) state.metric = String(saved.metric);
        if (saved.tab) state.tab = String(saved.tab);
        if (saved.start) state.start = String(saved.start);
        if (saved.end) state.end = String(saved.end);
        state.expanded = Boolean(saved.expanded);
      }
    } catch (err) {
      /* private mode / disabled storage: defaults are fine */
    }
  }

  function saveState() {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch (err) {
      /* ignore */
    }
  }

  /* ---------- dates ---------- */
  function localISO(date) {
    var y = date.getFullYear();
    var m = String(date.getMonth() + 1).padStart(2, "0");
    var d = String(date.getDate()).padStart(2, "0");
    return y + "-" + m + "-" + d;
  }

  function todayISO() {
    return localISO(new Date());
  }

  function shiftDays(iso, delta) {
    var parts = iso.split("-");
    var date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
    date.setDate(date.getDate() + delta);
    return localISO(date);
  }

  function resolveRange() {
    var today = todayISO();
    if (state.range === "today") return { start: today, end: today };
    if (state.range === "yesterday") {
      var yesterday = shiftDays(today, -1);
      return { start: yesterday, end: yesterday };
    }
    if (state.range === "custom") {
      var start = state.start || shiftDays(today, -29);
      var end = state.end || today;
      if (start > end) { var swap = start; start = end; end = swap; }
      return { start: start, end: end };
    }
    var days = parseInt(state.range, 10) || 30;
    return { start: shiftDays(today, -(days - 1)), end: today };
  }

  /* ---------- formatting ---------- */
  function formatNumber(value) {
    var v = Number(value) || 0;
    if (v >= 1e8) return (v / 1e8).toFixed(2) + "亿";
    if (v >= 1e4) return (v / 1e4).toFixed(2) + "万";
    return Math.round(v).toLocaleString("en-US");
  }

  function formatValue(metric, value) {
    if (metric === "cost") return "$" + (Number(value) || 0).toFixed(2);
    return formatNumber(value);
  }

  /* Known subtotal with a 「部分」 marker; "—" only when nothing is priced. */
  function formatCostSubtotal(breakdown) {
    if (breakdown.cost_any_known === false) return "—";
    return "$" + (Number(breakdown.cost_total) || 0).toFixed(2);
  }

  function partialMarker() {
    return '<span class="partial">部分</span>';
  }

  function formatPercent(share) {
    var pct = (Number(share) || 0) * 100;
    if (pct > 0 && pct < 0.1) return "<0.1%";
    return pct.toFixed(1) + "%";
  }

  function formatTimestamp(iso) {
    if (!iso) return "—";
    var date = new Date(iso);
    if (isNaN(date.getTime())) return iso;
    var pad = function (n) { return String(n).padStart(2, "0"); };
    return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) +
      " " + pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds());
  }

  function colorFor(name, index) {
    if (SOURCE_COLORS[name]) return SOURCE_COLORS[name];
    var hash = 0;
    for (var i = 0; i < name.length; i += 1) hash = (hash * 31 + name.charCodeAt(i)) % 997;
    return PALETTE[(index === undefined ? hash : index) % PALETTE.length];
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"']/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch];
    });
  }

  /* ---------- api ---------- */
  function getJSON(url) {
    return fetch(url, { headers: { Accept: "application/json" } }).then(function (res) {
      if (!res.ok) throw new Error(url + " -> " + res.status);
      return res.json();
    });
  }

  /* ---------- chart ---------- */
  function renderChart(days, series, metric) {
    var element = document.getElementById("chart");
    if (!chart) {
      chart = window.echarts.init(element);
      window.addEventListener("resize", function () { chart.resize(); });
    }
    var sources = Object.keys(series);
    var barSize = days.length > 45 ? 10 : days.length > 20 ? 18 : 26;
    var option = {
      backgroundColor: "transparent",
      grid: { left: 8, right: 16, top: 44, bottom: 8, containLabel: true },
      legend: {
        top: 4,
        left: "center",
        icon: "roundRect",
        itemWidth: 10,
        itemHeight: 10,
        textStyle: { color: "#c9d1d9" }
      },
      tooltip: {
        trigger: "axis",
        axisPointer: { type: "shadow" },
        backgroundColor: "rgba(22, 27, 34, 0.96)",
        borderColor: "#30363d",
        textStyle: { color: "#e6edf3", fontSize: 12 },
        formatter: function (params) {
          if (!params || !params.length) return "";
          var total = 0;
          var lines = params.map(function (item) {
            var value = Number(item.value) || 0;
            total += value;
            return item.marker + item.seriesName + "：" + formatValue(metric, value);
          });
          lines.push(
            '<div style="margin-top:4px;border-top:1px solid #30363d;padding-top:4px">' +
            "合计：" + formatValue(metric, total) + "</div>"
          );
          return "<strong>" + params[0].axisValue + "</strong><br>" + lines.join("<br>");
        }
      },
      xAxis: {
        type: "category",
        data: days,
        axisLine: { lineStyle: { color: "#30363d" } },
        axisTick: { show: false },
        axisLabel: {
          color: "#8b949e",
          fontSize: 11,
          rotate: 45,
          hideOverlap: true,
          interval: days.length > 60 ? "auto" : 0
        }
      },
      yAxis: {
        type: "value",
        splitLine: { lineStyle: { color: "rgba(48, 54, 61, 0.6)" } },
        axisLabel: {
          color: "#8b949e",
          fontSize: 11,
          formatter: function (value) {
            return metric === "cost" ? "$" + value : formatNumber(value);
          }
        }
      },
      series: sources.map(function (name) {
        return {
          name: name,
          type: "bar",
          stack: "usage",
          barMaxWidth: barSize,
          emphasis: { focus: "series" },
          itemStyle: { color: colorFor(name), borderRadius: [2, 2, 0, 0] },
          data: series[name] || []
        };
      })
    };
    chart.setOption(option, true);
  }

  /* ---------- summary ---------- */
  function renderSummary(range, metric, daily, breakdown) {
    var totals = {};
    var grand = 0;
    var days = daily.days || [];
    Object.keys(daily.series || {}).forEach(function (source) {
      var values = daily.series[source] || [];
      for (var i = 0; i < values.length; i += 1) {
        totals[source] = (totals[source] || 0) + (Number(values[i]) || 0);
        grand += Number(values[i]) || 0;
      }
    });
    var costKnown = breakdown.cost_any_known !== false;
    var costText = formatCostSubtotal(breakdown);
    var partial = breakdown.cost_partial
      ? '<span class="partial">（部分）</span>'
      : "";
    document.getElementById("summary").innerHTML =
      escapeHtml(range.start + " ~ " + range.end) +
      " ｜ " + escapeHtml(METRIC_LABELS[metric] || metric) +
      " ｜ 合计 <strong>" + formatValue(metric, metric === "cost" ? breakdown.total : grand) + "</strong>" +
      " ｜ 等效估值 <strong>" + (costKnown ? costText : "—") + "</strong>" + partial +
      " ｜ 数据源 " + escapeHtml(Object.keys(totals).sort().join(" / ") || "无");
  }

  /* ---------- breakdown table ---------- */
  function renderBreakdown(breakdown, metric) {
    var body = document.getElementById("breakdown-body");
    var rows = breakdown.rows || [];
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="5" class="muted">该时间段内没有数据</td></tr>';
      return;
    }
    var limit = state.expanded ? rows.length : TOP_ROWS;
    var visible = rows.slice(0, limit);
    var rest = rows.slice(limit);
    var html = visible.map(function (row) {
      return rowHtml(row, metric, state.tab);
    }).join("");

    if (rest.length) {
      var restValue = rest.reduce(function (sum, row) { return sum + (Number(row.value) || 0); }, 0);
      var restShare = rest.reduce(function (sum, row) { return sum + (Number(row.share) || 0); }, 0);
      html += '<tr class="more-row" id="more-row"><td colspan="5">其他 ' + rest.length +
        " 个（合计 " + formatPercent(restShare) + "，共 " +
        formatValue(metric, restValue) + "）· 点击展开</td></tr>";
    } else if (state.expanded && rows.length > TOP_ROWS) {
      html += '<tr class="more-row" id="more-row"><td colspan="5">收起</td></tr>';
    }
    body.innerHTML = html;

    var moreRow = document.getElementById("more-row");
    if (moreRow) {
      moreRow.addEventListener("click", function () {
        state.expanded = !state.expanded;
        saveState();
        renderBreakdown(breakdown, metric);
      });
    }
  }

  /* Pure cost-cell formatting, split out so it can be unit-tested in node.
     A group with a known subtotal keeps showing it (marked 「部分」) even when
     some of its events are unpriced; "—" only when nothing is priced. */
  function formatCostCells(row) {
    var anyKnown = row.cost_any_known;
    if (anyKnown === undefined || anyKnown === null) {
      anyKnown = row.cost_known !== false;  // older payloads only had cost_known
    }
    var partial = row.cost_partial === undefined
      ? anyKnown && !
        (row.cost_known !== false)
      : Boolean(row.cost_partial);
    if (!anyKnown) {
      return { cost: "—", costShare: "—", partial: false };
    }
    var costText = "$" + (Number(row.cost) || 0).toFixed(2);
    var shareText = formatPercent(row.cost_share);
    return {
      cost: partial ? costText + " " + partialMarker() : costText,
      costShare: partial ? shareText + " " + partialMarker() : shareText,
      partial: partial
    };
  }

  function rowHtml(row, metric, by) {
    var sharePct = Math.max(Math.min(Number(row.share) || 0, 1), 0) * 100;
    var raws = (row.raw || []).filter(function (value) { return value; });
    var title = raws.length ? ' title="' + escapeHtml(raws.join("\n")) + '"' : "";
    // The Coding Agent tab colours each bar like its chart series and shows the
    // vendor logo; other tabs keep the single accent colour and the plain dot.
    var barColor = by === "source" ? colorFor(row.key) : ACCENT_COLOR;
    var logo = by === "source" ? SOURCE_LOGOS[row.key] : null;
    var marker = logo
      ? '<img class="logo" src="' + logo + '" alt="" width="16" height="16">'
      : '<span class="dot" style="background:' + barColor + '"></span>';
    var cells = formatCostCells(row);
    return "<tr>" +
      '<td class="col-name"><div class="name-cell">' +
      marker +
      "<span" + title + ">" + escapeHtml(row.key) + "</span>" +
      "</div></td>" +
      '<td class="col-share"><div class="share-wrap">' +
      '<div class="share-track"><div class="share-fill" style="width:' + sharePct.toFixed(2) +
      "%;background:" + barColor + '"></div></div>' +
      '<span class="share-pct">' + formatPercent(row.share) + "</span>" +
      "</div></td>" +
      '<td class="col-value">' + formatValue(metric, row.value) + "</td>" +
      '<td class="col-cost">' + cells.cost + "</td>" +
      '<td class="col-cost-share">' + cells.costShare + "</td>" +
      "</tr>";
  }

  /* ---------- refresh ---------- */
  function refresh() {
    var generation = (requestGen += 1);
    var range = resolveRange();
    var metric = state.metric;
    var tab = state.tab;
    var query = "start=" + encodeURIComponent(range.start) + "&end=" + encodeURIComponent(range.end) +
      "&metric=" + encodeURIComponent(metric);
    return Promise.all([
      getJSON("/api/daily?" + query),
      getJSON("/api/breakdown?" + query + "&by=" + encodeURIComponent(tab)),
      getJSON("/api/meta")
    ]).then(function (results) {
      if (generation !== requestGen) return;  // a newer request already won
      var daily = results[0];
      var breakdown = results[1];
      var meta = results[2];
      cached = { days: daily.days || [], series: daily.series || {}, rows: breakdown.rows || [] };
      renderChart(daily.days || [], daily.series || {}, metric);
      renderSummary(range, metric, daily, breakdown);
      renderBreakdown(breakdown, metric);
      document.getElementById("last-ingest").textContent =
        "采集时间：" + formatTimestamp(meta.last_ingest_at);
    }).catch(function (err) {
      if (generation !== requestGen) return;  // stale failure: ignore it too
      document.getElementById("summary").textContent = "加载失败：" + err.message;
      document.getElementById("breakdown-body").innerHTML =
        '<tr><td colspan="5" class="muted">加载失败：' + escapeHtml(err.message) + "</td></tr>";
    });
  }

  /* ---------- controls ---------- */
  function syncControls() {
    Array.prototype.forEach.call(document.querySelectorAll("#range-buttons button"), function (button) {
      button.classList.toggle("active", button.dataset.range === state.range);
    });
    Array.prototype.forEach.call(document.querySelectorAll("#tabs button"), function (button) {
      button.classList.toggle("active", button.dataset.tab === state.tab);
    });
    document.getElementById("metric-select").value = state.metric;
    var custom = document.getElementById("custom-range");
    custom.classList.toggle("hidden", state.range !== "custom");
    var range = resolveRange();
    document.getElementById("start-date").value = range.start;
    document.getElementById("end-date").value = range.end;
  }

  function bindControls() {
    document.getElementById("range-buttons").addEventListener("click", function (event) {
      var button = event.target.closest("button[data-range]");
      if (!button) return;
      state.range = button.dataset.range;
      state.expanded = false;
      if (state.range === "custom") {
        var range = resolveRange();
        state.start = range.start;
        state.end = range.end;
      }
      saveState();
      syncControls();
      refresh();
    });

    document.getElementById("start-date").addEventListener("change", function (event) {
      state.start = event.target.value;
      state.range = "custom";
      saveState();
      syncControls();
      refresh();
    });

    document.getElementById("end-date").addEventListener("change", function (event) {
      state.end = event.target.value;
      state.range = "custom";
      saveState();
      syncControls();
      refresh();
    });

    document.getElementById("metric-select").addEventListener("change", function (event) {
      state.metric = event.target.value;
      state.expanded = false;
      saveState();
      refresh();
    });

    document.getElementById("tabs").addEventListener("click", function (event) {
      var button = event.target.closest("button[data-tab]");
      if (!button) return;
      state.tab = button.dataset.tab;
      state.expanded = false;
      saveState();
      syncControls();
      refresh();
    });

    document.getElementById("btn-ingest").addEventListener("click", function () {
      var button = document.getElementById("btn-ingest");
      var status = document.getElementById("ingest-status");
      var restore = function (text, delay) {
        window.setTimeout(function () {
          button.textContent = "立即采集";
          button.disabled = false;
          if (status) status.textContent = text || "";
        }, delay || 4000);
      };
      button.disabled = true;
      button.textContent = "采集中…";
      if (status) status.textContent = "";
      fetch("/api/ingest", { method: "POST" })
        .then(function (res) {
          if (!res.ok) {
            return res.text().then(function (body) {
              var detail = body ? "：" + body.slice(0, 200) : "";
              throw new Error("采集失败 (HTTP " + res.status + ")" + detail);
            });
          }
          return res.json();
        })
        .then(function (result) {
          var failures = [];
          Object.keys(result.sources || {}).forEach(function (name) {
            var stats = result.sources[name] || {};
            if (stats.errors) {
              failures.push(name + " " + stats.errors + " 个文件失败");
            }
          });
          if (result.errors || failures.length) {
            button.textContent = "采集有错误";
            if (status) {
              status.textContent = failures.length
                ? failures.join("；")
                : "采集过程中有 " + result.errors + " 个错误，详见服务日志";
            }
            restore("", 8000);
          } else {
            button.textContent = "已采集 " + (result.rows || 0) + " 行";
            if (status) status.textContent = "";
            restore("", 1500);
          }
          return refresh();
        })
        .catch(function (err) {
          button.textContent = "采集失败";
          if (status) status.textContent = err.message;
          restore("", 8000);
          console.error(err);
        });
    });
  }

  /* ---------- boot ---------- */
  if (typeof module !== "undefined" && module.exports) {
    // Test hooks (node): the browser keeps everything private.
    module.exports = {
      formatCostCells: formatCostCells,
      formatPercent: formatPercent,
      formatNumber: formatNumber,
      formatCostSubtotal: formatCostSubtotal
    };
    return;
  }

  loadState();
  if (!state.start || !state.end) {
    var initial = resolveRange();
    state.start = initial.start;
    state.end = initial.end;
  }
  syncControls();
  bindControls();
  refresh();
})();
