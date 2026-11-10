// Review navigation only. Each workspace remains maintained in its existing source files.
(() => {
  const root = document.getElementById('rl-mobile-review');
  const editor = root.querySelector('#rl-editor-review');
  const camera = root.querySelector('#rl-camera-review');
  let view = 'camera';
  const valid = new Set(['editor', 'camera', 'import', 'tether']);

  function show(next, save = false) {
    if (!valid.has(next)) return;
    view = next;
    editor.hidden = view !== 'editor';
    camera.hidden = view === 'editor';
    root.querySelectorAll('[data-review-view]').forEach(button => {
      button.setAttribute('aria-pressed', String(button.dataset.reviewView === view));
    });
    const target = view === 'editor' ? editor : camera;
    target.dispatchEvent(new CustomEvent('review-navigate', {
      detail: { screen: view === 'camera' || view === 'editor' ? 'home' : view },
    }));
    if (save && window.openai?.setWidgetState) {
      window.openai.setWidgetState({
        modelContent: { review: 'RawLab mobile editor and camera', view },
        privateContent: { view },
      }).catch(() => {});
    }
  }

  root.querySelectorAll('[data-review-view]').forEach(button => {
    button.addEventListener('click', () => show(button.dataset.reviewView, true));
  });
  root.addEventListener('review-open-camera', () => show('camera', true));
  root.addEventListener('review-open-editor', () => show('editor', true));
  window.addEventListener('openai:set_globals', event => {
    const next = event.detail?.globals?.widgetState?.privateContent?.view;
    if (valid.has(next)) show(next);
  });
  show(window.openai?.widgetState?.privateContent?.view || 'camera');
})();
