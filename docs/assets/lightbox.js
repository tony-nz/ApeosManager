// Click a screenshot to see it full size.
//
// The images on these pages are 2640px wide and laid out at a fraction of that, so the
// detail that justified including them -- a fault code repeated eleven times, a meter
// against its cap, a status badge that disagrees with the machine under it -- cannot
// actually be read in place.
//
// Built on <dialog>, which brings Escape, a focus trap and an inert background with it.
// If the element is unsupported, or scripting is off, nothing is bound and the images
// stay exactly as they were: still visible, just not enlargeable.
(function () {
    'use strict';

    var figures = Array.prototype.slice.call(document.querySelectorAll('figure img'));
    if (!figures.length) { return; }
    if (typeof HTMLDialogElement === 'undefined' ||
        !HTMLDialogElement.prototype.showModal) { return; }

    var dialog = document.createElement('dialog');
    dialog.className = 'lightbox';
    dialog.innerHTML =
        '<form method="dialog">' +
        '<button class="close" aria-label="Close">&times;</button>' +
        '</form>' +
        '<div class="lightbox-inner">' +
        '<img alt="">' +
        '<p class="cap"></p>' +
        '</div>';
    document.body.appendChild(dialog);

    var big = dialog.querySelector('img');
    var cap = dialog.querySelector('.cap');
    var opener = null;

    function open(source) {
        opener = source;
        big.src = source.src;
        // The alt text is the description; reuse it rather than writing a second one
        // that would drift from it.
        big.alt = source.alt;
        var figcaption = source.closest('figure').querySelector('figcaption');
        cap.textContent = figcaption ? figcaption.textContent.replace(/\s+/g, ' ').trim() : '';
        cap.hidden = !cap.textContent;
        document.body.classList.add('lightbox-open');
        dialog.showModal();
        big.focus();
    }

    figures.forEach(function (img) {
        // Reachable by keyboard as well as by pointer: a control that only a mouse can
        // use is not a control.
        img.tabIndex = 0;
        img.setAttribute('role', 'button');
        img.setAttribute('aria-label', 'Enlarge: ' + (img.alt || 'screenshot'));

        img.addEventListener('click', function () { open(img); });
        img.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(img); }
        });
    });

    // Clicking the image, or the backdrop around it, closes.
    big.addEventListener('click', function () { dialog.close(); });
    dialog.addEventListener('click', function (e) {
        if (e.target === dialog || e.target.classList.contains('lightbox-inner')) {
            dialog.close();
        }
    });

    // Runs for Escape too, which <dialog> handles on its own.
    dialog.addEventListener('close', function () {
        document.body.classList.remove('lightbox-open');
        big.removeAttribute('src');
        if (opener) { opener.focus(); opener = null; }
    });
})();
