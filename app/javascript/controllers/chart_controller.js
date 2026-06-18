import { Controller } from "@hotwired/stimulus"

// Recharts → Chart.js 변환. 캔버스마다 type/data 값을 받아 차트를 그린다.
const BLUE = "#3b82f6"
const BLUE_SOFT = "#93c5fd"
const DANGER = "#ef4444"
const MUTED = "#a1a1aa"
const INK = "#18181b"
const AXIS = "#71717a"

export default class extends Controller {
  static values = { type: String, data: Array, avg: Number }

  connect() {
    if (typeof Chart === "undefined") {
      // Chart.js(CDN)가 아직 로드되지 않았으면 잠시 후 재시도
      this._timer = setTimeout(() => this.connect(), 60)
      return
    }
    if (window.ChartDataLabels) Chart.register(window.ChartDataLabels)

    const builder = this[`build_${this.typeValue}`]
    if (builder) this.chart = new Chart(this.element, builder.call(this))
  }

  disconnect() {
    if (this._timer) clearTimeout(this._timer)
    if (this.chart) this.chart.destroy()
  }

  get base() {
    return {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false }, tooltip: { enabled: false } },
    }
  }

  /* Block 3 — 점포당 월매출 순위 (가로 막대) */
  build_revenue() {
    const d = this.dataValue
    return {
      type: "bar",
      data: {
        labels: d.map((x) => x.name),
        datasets: [
          {
            data: d.map((x) => x.value),
            backgroundColor: d.map((x) => (x.highlight ? BLUE : MUTED)),
            borderRadius: 4,
            barThickness: 16,
          },
        ],
      },
      options: {
        ...this.base,
        indexAxis: "y",
        layout: { padding: { right: 28 } },
        plugins: {
          ...this.base.plugins,
          datalabels: { anchor: "end", align: "right", color: AXIS, font: { size: 11 }, formatter: (v) => v },
        },
        scales: {
          x: { display: false },
          y: { grid: { display: false }, border: { display: false }, ticks: { color: AXIS, font: { size: 12 } } },
        },
      },
    }
  }

  /* Block 4 — 경쟁도 (세로 막대 2개) */
  build_competition() {
    const d = this.dataValue
    return {
      type: "bar",
      data: {
        labels: d.map((x) => x.name),
        datasets: [
          {
            data: d.map((x) => x.value),
            backgroundColor: d.map((x) => (x.kind === "danger" ? DANGER : MUTED)),
            borderRadius: 6,
            maxBarThickness: 90,
          },
        ],
      },
      options: {
        ...this.base,
        layout: { padding: { top: 28 } },
        plugins: {
          ...this.base.plugins,
          datalabels: { anchor: "end", align: "top", color: INK, font: { size: 13, weight: 700 }, formatter: (v) => `${v}개` },
        },
        scales: {
          x: { grid: { display: false }, border: { display: false }, ticks: { color: AXIS, font: { size: 12 } } },
          y: { display: false, beginAtZero: true },
        },
      },
    }
  }

  /* Block 5 — 연령대별 매출 비중 (세로 막대 + 평균선) */
  build_age() {
    const d = this.dataValue
    const avg = this.avgValue
    return {
      type: "bar",
      data: {
        labels: d.map((x) => x.name),
        datasets: [
          {
            data: d.map((x) => x.value),
            backgroundColor: d.map((x) => (x.highlight ? BLUE : MUTED)),
            borderRadius: 6,
            maxBarThickness: 36,
            datalabels: { anchor: "end", align: "top", color: AXIS, font: { size: 12 }, formatter: (v) => `${v}%` },
          },
          {
            type: "line",
            data: d.map(() => avg),
            borderColor: DANGER,
            borderDash: [5, 4],
            borderWidth: 1.5,
            pointRadius: 0,
            datalabels: { display: false },
          },
        ],
      },
      options: {
        ...this.base,
        layout: { padding: { top: 28 } },
        plugins: {
          ...this.base.plugins,
          datalabels: {},
        },
        scales: {
          x: { grid: { display: false }, border: { display: false }, ticks: { color: AXIS, font: { size: 12 } } },
          y: { display: false, min: 0, max: 30 },
        },
      },
    }
  }

  /* Block 6 — 시간대별 매출 vs 학생 이용 (이중 축) */
  build_timeslot() {
    const d = this.dataValue
    return {
      type: "bar",
      data: {
        labels: d.map((x) => x.name),
        datasets: [
          {
            label: "매출",
            data: d.map((x) => x.sales),
            backgroundColor: BLUE_SOFT,
            borderRadius: 4,
            maxBarThickness: 32,
            yAxisID: "y",
            datalabels: { display: false },
          },
          {
            type: "line",
            label: "학생 이용",
            data: d.map((x) => x.students),
            borderColor: DANGER,
            borderWidth: 2,
            pointRadius: 4,
            pointBackgroundColor: DANGER,
            yAxisID: "y1",
            datalabels: { display: false },
          },
        ],
      },
      options: {
        ...this.base,
        plugins: {
          ...this.base.plugins,
          tooltip: {
            enabled: true,
            callbacks: {
              label: (ctx) =>
                ctx.dataset.label === "매출" ? `매출 ${ctx.parsed.y}M` : `학생 이용 ${ctx.parsed.y}명`,
            },
          },
        },
        scales: {
          x: { grid: { display: false }, border: { display: false }, ticks: { color: AXIS, font: { size: 12 } } },
          y: { position: "left", border: { display: false }, ticks: { color: AXIS, font: { size: 12 } } },
          y1: { position: "right", grid: { drawOnChartArea: false }, border: { display: false }, ticks: { color: AXIS, font: { size: 12 } } },
        },
      },
    }
  }

  /* Block 7 — 상권 문제점 TOP5 (가로 막대, ink) */
  build_problems() {
    const d = this.dataValue
    return {
      type: "bar",
      data: {
        labels: d.map((x) => x.name),
        datasets: [{ data: d.map((x) => x.value), backgroundColor: INK, borderRadius: 4, barThickness: 16 }],
      },
      options: {
        ...this.base,
        indexAxis: "y",
        layout: { padding: { right: 28 } },
        plugins: {
          ...this.base.plugins,
          datalabels: { anchor: "end", align: "right", color: AXIS, font: { size: 11 }, formatter: (v) => `${v}명` },
        },
        scales: {
          x: { display: false },
          y: { grid: { display: false }, border: { display: false }, ticks: { color: AXIS, font: { size: 11 } } },
        },
      },
    }
  }
}
