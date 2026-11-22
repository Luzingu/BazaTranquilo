// Tema do painel (claro ou escuro), aplicado antes de a página aparecer para
// não piscar. Sem escolha guardada, segue o tema do computador.
(() => {
  let saved = null;
  try {
    saved = localStorage.getItem('baza-tema');
  } catch {
    // Sem acesso ao armazenamento: segue o sistema.
  }
  const dark = saved ? saved === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
})();
