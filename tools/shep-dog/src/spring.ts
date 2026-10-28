// A damped spring (written for Shep): used by the motion engine and the pose driver.
/** Damped spring, semi-implicit Euler in fixed sub-steps so a slow frame cannot blow it up. */
export class Spring {
  x: number
  v = 0
  constructor(x = 0, public k = 160, public c = 12) {
    this.x = x
  }
  step(dt: number, target: number): void {
    let left = Math.min(dt, 0.1)
    while (left > 1e-6) {
      const h = Math.min(left, 1 / 120)
      this.v += (this.k * (target - this.x) - this.c * this.v) * h
      this.x += this.v * h
      left -= h
    }
  }
  kick(velocity: number): void {
    this.v += velocity
  }
}
