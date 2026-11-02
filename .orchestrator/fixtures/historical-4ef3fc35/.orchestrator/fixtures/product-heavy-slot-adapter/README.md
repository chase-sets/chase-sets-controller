# Product Heavy-Slot Adapter

Byte-identical `scripts/lib/heavy-slot.mjs` from product commit
`0f3e27ce77289a8dbc5c96d3889946a101dc3cea`, Git blob
`30327bd78fe8eb15130f63faafee42172b4d8eed`.

The preload regression verifies this identity, then copies the adapter into
its disposable repository. Client discovery and admission use only that
fixture's controller root. Tests never consult the live product checkout.
