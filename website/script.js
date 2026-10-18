// Without JavaScript, the platform links lead to three visible setup guides.
// Enhance them into keyboard-accessible tabs when scripting is available.
const picker = document.querySelector('.platform-picker');
const links = [...picker.querySelectorAll('.platform-link')];
const panels = links.map((link) => document.querySelector(link.hash));

picker.setAttribute('role', 'tablist');
links.forEach((link, index) => {
  link.id = `tab-${panels[index].id}`;
  link.setAttribute('role', 'tab');
  link.setAttribute('aria-controls', panels[index].id);
  panels[index].setAttribute('role', 'tabpanel');
  panels[index].setAttribute('aria-labelledby', link.id);
  panels[index].tabIndex = 0;
});

function selectPlatform(index) {
  links.forEach((link, current) => {
    const selected = current === index;
    link.setAttribute('aria-selected', String(selected));
    link.tabIndex = selected ? 0 : -1;
    panels[current].hidden = !selected;
  });
}

function selectPlatformFromHash() {
  const index = links.findIndex((link) => link.hash === window.location.hash);
  if (index !== -1) selectPlatform(index);
}

links.forEach((link, index) => {
  link.addEventListener('click', (event) => {
    event.preventDefault();
    selectPlatform(index);
    history.replaceState(null, '', link.hash);
  });
  link.addEventListener('keydown', (event) => {
    if (event.key === ' ') {
      event.preventDefault();
      link.click();
      return;
    }
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % links.length;
    if (event.key === 'ArrowLeft') next = (index - 1 + links.length) % links.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = links.length - 1;
    if (next === undefined) return;
    event.preventDefault();
    links[next].click();
    links[next].focus();
  });
});

selectPlatform(0);
selectPlatformFromHash();
window.addEventListener('hashchange', selectPlatformFromHash);
