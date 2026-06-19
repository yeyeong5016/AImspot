import { Controller } from "@hotwired/stimulus"

// Leaflet 지도 (react-leaflet TradeMap 대체)
export default class extends Controller {
  static values = { station: Object, areas: Array, selected: String }

  connect() {
    if (typeof L === "undefined") {
      this._timer = setTimeout(() => this.connect(), 60)
      return
    }

    const station = this.stationValue
    const areas = this.areasValue
    const selected = areas.find((a) => a.code === this.selectedValue) || areas[0]

    this.map = L.map(this.element, { scrollWheelZoom: false, zoomControl: true }).setView(
      [station.lat, station.lng],
      15,
    )

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: "&copy; OpenStreetMap",
    }).addTo(this.map)

    // 선택 상권 폴리곤
    if (selected.polygon) {
      L.polygon(selected.polygon, {
        color: "#ef4444",
        fillColor: "#ef4444",
        fillOpacity: 0.25,
        weight: 2,
      })
        .addTo(this.map)
        .bindTooltip(selected.label)
    }

    // 기타 상권 마커
    areas
      .filter((a) => a.code !== selected.code)
      .forEach((a) => {
        L.circleMarker([a.lat, a.lng], {
          color: "#a1a1aa",
          fillColor: "#ffffff",
          fillOpacity: 0.9,
          weight: 2,
          radius: 9,
        })
          .addTo(this.map)
          .bindTooltip(a.label)
      })

    // 성신여대입구역 중심점
    L.circleMarker([station.lat, station.lng], {
      color: "#3b82f6",
      fillColor: "#3b82f6",
      fillOpacity: 1,
      weight: 2,
      radius: 6,
    })
      .addTo(this.map)
      .bindTooltip(station.label, { permanent: true, direction: "top" })
  }

  disconnect() {
    if (this._timer) clearTimeout(this._timer)
    if (this.map) this.map.remove()
  }
}
