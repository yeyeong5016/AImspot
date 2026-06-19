import { Controller } from "@hotwired/stimulus"

// 업종(대>중>소) 연동 드롭다운 + 상권 선택 (React IndustryForm 대체)
export default class extends Controller {
  static targets = ["large", "mid", "biz", "chip", "chipText", "area", "submit"]
  static values = { categories: Array }

  connect() {
    this.refreshChip()
    this.refreshSubmit()
  }

  changeLarge() {
    const node = this.categoriesValue.find((c) => c.label === this.largeTarget.value)
    this.fill(this.midTarget, "중분류", (node?.children || []).map((c) => c.label))
    this.disable(this.midTarget, !node)
    this.fill(this.bizTarget, "업종", [])
    this.disable(this.bizTarget, true)
    this.refreshChip()
    this.refreshSubmit()
  }

  changeMid() {
    const large = this.categoriesValue.find((c) => c.label === this.largeTarget.value)
    const mid = large?.children.find((c) => c.label === this.midTarget.value)
    this.fill(this.bizTarget, "업종", (mid?.children || []).map((c) => c.label))
    this.disable(this.bizTarget, !mid)
    this.refreshChip()
    this.refreshSubmit()
  }

  changeBiz() {
    this.refreshChip()
    this.refreshSubmit()
  }

  changeArea() {
    this.refreshSubmit()
  }

  // ── helpers ─────────────────────────────────────────────
  fill(select, placeholder, options) {
    select.innerHTML = ""
    const opt0 = document.createElement("option")
    opt0.value = ""
    opt0.textContent = placeholder
    select.appendChild(opt0)
    options.forEach((label) => {
      const o = document.createElement("option")
      o.value = label
      o.textContent = label
      select.appendChild(o)
    })
    select.value = ""
  }

  disable(select, off) {
    select.disabled = off
    if (off) {
      select.classList.add("bg-[var(--color-zinc-bg)]", "text-muted-foreground")
      select.classList.remove("bg-card", "text-foreground")
    } else {
      select.classList.remove("bg-[var(--color-zinc-bg)]", "text-muted-foreground")
      select.classList.add("bg-card", "text-foreground")
    }
  }

  refreshChip() {
    const l = this.largeTarget.value
    const m = this.midTarget.value
    const b = this.bizTarget.value
    if (l || m || b) {
      this.chipTextTarget.textContent = [l || "대분류", m || "중분류", b || "업종"].join(" > ")
      this.chipTarget.classList.remove("hidden")
    } else {
      this.chipTarget.classList.add("hidden")
    }
  }

  refreshSubmit() {
    const areaChecked = this.areaTargets.some((r) => r.checked)
    const ok =
      this.largeTarget.value && this.midTarget.value && this.bizTarget.value && areaChecked
    this.submitTarget.disabled = !ok
    if (ok) {
      this.submitTarget.classList.remove("cursor-not-allowed", "bg-brand/50")
      this.submitTarget.classList.add("bg-brand", "hover:brightness-95")
    } else {
      this.submitTarget.classList.add("cursor-not-allowed", "bg-brand/50")
      this.submitTarget.classList.remove("bg-brand", "hover:brightness-95")
    }
  }
}
