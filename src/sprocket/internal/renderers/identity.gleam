import sprocket/internal/reconcile.{type ReconciledElement}
import sprocket/internal/render.{type Renderer, Renderer}

pub fn identity_renderer() -> Renderer(ReconciledElement) {
  Renderer(render: fn(el: ReconciledElement) { el })
}
