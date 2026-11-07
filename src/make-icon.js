#!/usr/bin/env osascript -l JavaScript
// Draws the Phone Link icon (1024x1024): a dark rounded square, a pale phone outline,
// and two sound arcs beside it in the accent blue. Paths only; no font needed.
ObjC.import('AppKit');

function run(argv) {
	const S = 1024;
	const img = $.NSImage.alloc.initWithSize($.NSMakeSize(S, S));
	img.lockFocus;
	const rgb = (r, g, b) => $.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, 1.0);
	const rect = (x, y, w, h, r) =>
		$.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(x, y, w, h), r, r);

	rgb(0.086, 0.086, 0.098).set;
	rect(0, 0, S, S, 224).fill;

	const phone = rect(300, 212, 300, 600, 64);
	phone.lineWidth = 44;
	rgb(0.886, 0.878, 0.859).set;
	phone.stroke;
	rect(410, 720, 80, 22, 11).fill;

	rgb(0.561, 0.659, 0.776).set;
	[130, 230].forEach(r => {
		const arc = $.NSBezierPath.bezierPath;
		arc.appendBezierPathWithArcWithCenterRadiusStartAngleEndAngle($.NSMakePoint(620, 512), r, -40, 40);
		arc.lineWidth = 44;
		arc.lineCapStyle = 1;
		arc.stroke;
	});
	img.unlockFocus;
	const rep = $.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation);
	rep.representationUsingTypeProperties(4, $.NSDictionary.dictionary).writeToFileAtomically($(argv[0]), true);
	return argv[0];
}
