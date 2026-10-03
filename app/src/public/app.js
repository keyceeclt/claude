// Show the lost-reason picker only when a lost stage is chosen.
document.querySelectorAll('select[data-lost-stages]').forEach((sel) => {
    const lost = sel.dataset.lostStages.split(',');
    const target = document.getElementById(sel.dataset.target);
    const sync = () => { if (target) target.hidden = !lost.includes(sel.value); };
    sel.addEventListener('change', sync);
    sync();
});
// Confirm destructive-looking actions.
document.querySelectorAll('form[data-confirm]').forEach((f) => {
    f.addEventListener('submit', (e) => { if (!window.confirm(f.dataset.confirm)) e.preventDefault(); });
});
// Load a CSV file into the import textarea.
document.querySelectorAll('input[type=file][data-into]').forEach((input) => {
    input.addEventListener('change', async () => {
        const file = input.files[0];
        if (file) document.getElementById(input.dataset.into).value = await file.text();
    });
});
// WhatsApp links send the (possibly edited) draft text.
document.querySelectorAll('a[data-wa-from]').forEach((a) => {
    a.addEventListener('click', () => {
        const text = document.getElementById(a.dataset.waFrom)?.value || '';
        const url = new URL(a.href);
        url.searchParams.set('text', text);
        a.href = url.toString();
    });
});
