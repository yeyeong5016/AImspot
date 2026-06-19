import { Controller } from "@hotwired/stimulus"

// 차별화 전략 체크박스 토글 + 동적 % 합산 + 순위 배지 (React strategy-advisor 대체)
export default class extends Controller {
  static targets = ["card", "total", "breakdown"]

  connect() {
    this._displayed = 0
    this.render()
  }

  toggle(event) {
    const card = event.currentTarget
    const isOn = card.dataset.on === "true"
    const onCount = this.cardTargets.filter((c) => c.dataset.on === "true").length

    // 최소 1개는 항상 선택 유지
    if (isOn && onCount <= 1) return

    card.dataset.on = (!isOn).toString()
    this.render()
  }

  render() {
    const selected = this.cardTargets.filter((c) => c.dataset.on === "true")

    // 선택된 카드만 % 내림차순으로 순위 부여
    const ranked = [...selected].sort(
      (a, b) => Number(b.dataset.boost) - Number(a.dataset.boost),
    )
    const rankById = {}
    ranked.forEach((c, i) => (rankById[c.dataset.id] = i + 1))

    this.cardTargets.forEach((card) => {
      const on = card.dataset.on === "true"
      const check = card.querySelector('[data-strategy-target="check"]')
      const icon = card.querySelector('[data-strategy-target="checkIcon"]')
      const badge = card.querySelector('[data-strategy-target="badge"]')

      // 카드 외곽선/배경
      card.style.border = on ? "2px solid #3b82f6" : "1px solid var(--color-zinc-border)"
      card.style.background = on ? "#f8faff" : "var(--color-card)"

      // 체크박스
      check.style.borderColor = on ? "#3b82f6" : "var(--color-zinc-border)"
      check.style.background = on ? "#3b82f6" : "transparent"
      icon.classList.toggle("hidden", !on)

      // 순위 배지
      if (on && rankById[card.dataset.id]) {
        badge.textContent = `전략 ${rankById[card.dataset.id]}순위`
        badge.classList.remove("hidden")
      } else {
        badge.classList.add("hidden")
      }
    })

    // 합산 % + count-up
    const total = selected.reduce((sum, c) => sum + Number(c.dataset.boost), 0)
    this.animateTo(total)

    // 기여 전략 목록
    this.breakdownTarget.textContent = selected
      .map((c) => {
        const title = c.querySelector("h3").childNodes[0].textContent.trim()
        return `${title} +${c.dataset.boost}%`
      })
      .join(" · ")
  }

  animateTo(target, duration = 500) {
    const from = this._displayed
    const start = performance.now()
    if (this._raf) cancelAnimationFrame(this._raf)

    const tick = (now) => {
      const t = Math.min((now - start) / duration, 1)
      const eased = 1 - Math.pow(1 - t, 3)
      const value = Math.round(from + (target - from) * eased)
      this.totalTarget.textContent = `+${value}%`
      if (t < 1) {
        this._raf = requestAnimationFrame(tick)
      } else {
        this._displayed = target
      }
    }
    this._raf = requestAnimationFrame(tick)
  }
}
