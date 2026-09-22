import { Controller } from "@hotwired/stimulus"

// Replaces this element with a fresh copy from the server at an interval,
// while it is active. The copy carries its own active flag, so polling stops
// by itself once the server says there is nothing left to wait for.
//
// A failed request leaves the element as it is and tries again next time.
export default class extends Controller {
  static values = { url: String, active: Boolean, interval: { type: Number, default: 2000 } }

  connect() {
    if (this.activeValue) this.schedule()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  schedule() {
    this.timer = setTimeout(() => this.refresh(), this.intervalValue)
  }

  async refresh() {
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "text/html" } })
      if (response.ok) {
        this.element.outerHTML = await response.text()
        return
      }
    } catch {
      // Network errors are retried on the next tick.
    }
    this.schedule()
  }
}
