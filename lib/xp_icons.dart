import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

/// Ícones coloridos e "gordinhos" no estilo do Windows 98/XP (desenhados em SVG, 32x32).
enum XpIcons {
  folder,
  note,
  heart,
  cassette,
  gear,
  find,
  film,
  youtube,
  duplicate,
  power,
  pin,
  list,
  plus,
  star,
  person,
  disc,
  play,
  shuffle,
  refresh,
  edit,
  computer,
}

const _svg = <XpIcons, String>{
  XpIcons.folder: '<path d="M2 7h10l3 3h15v17H2z" fill="#e8b830" stroke="#8a6410"/><path d="M2 12h28v15H2z" fill="#ffd96a" stroke="#8a6410"/><path d="M3 13h26" stroke="#fff6c8"/>',
  XpIcons.note: '<path d="M12 6l14-3v18" fill="none" stroke="#1d3c78" stroke-width="3"/><path d="M12 6v18" stroke="#1d3c78" stroke-width="3"/><ellipse cx="8.5" cy="24.5" rx="5" ry="4" fill="#3b8cf5" stroke="#0a246a"/><ellipse cx="22.5" cy="21.5" rx="5" ry="4" fill="#3b8cf5" stroke="#0a246a"/>',
  XpIcons.heart: '<path d="M16 28S3 19 3 11a6.5 6.5 0 0 1 13-2 6.5 6.5 0 0 1 13 2c0 8-13 17-13 17z" fill="#e0342a" stroke="#7a1010"/><ellipse cx="10" cy="10" rx="3" ry="2" fill="#ff9c8f"/>',
  XpIcons.cassette: '<rect x="2" y="6" width="28" height="20" rx="2" fill="#2a64e0" stroke="#0a246a"/><rect x="6" y="10" width="20" height="8" rx="1" fill="#dfe9f8"/><circle cx="11" cy="14" r="2.4" fill="#0a246a"/><circle cx="21" cy="14" r="2.4" fill="#0a246a"/><path d="M8 26l3-5h10l3 5" fill="#9fb6e0" stroke="#0a246a"/>',
  XpIcons.gear: '<circle cx="16" cy="16" r="10" fill="#bbb" stroke="#444" stroke-width="5" stroke-dasharray="4 3.85"/><circle cx="16" cy="16" r="8" fill="#d8d8d8" stroke="#555"/><circle cx="16" cy="16" r="3" fill="#ece9d8" stroke="#555"/>',
  XpIcons.find: '<rect x="4" y="3" width="18" height="24" fill="#fff" stroke="#555"/><path d="M7 8h12M7 12h12M7 16h8" stroke="#99a"/><circle cx="19" cy="18" r="6" fill="#bfe3ff" stroke="#1d3c78" stroke-width="2"/><path d="M23 22l6 6" stroke="#6b4b1d" stroke-width="4"/>',
  XpIcons.film: '<rect x="3" y="6" width="26" height="20" fill="#333" stroke="#000"/><rect x="7" y="9" width="18" height="14" fill="#ff8ab0"/><circle cx="13" cy="15" r="3" fill="#fff"/><path d="M8 23l6-6 4 4 3-3 4 5z" fill="#3b8cf5"/>',
  XpIcons.youtube: '<rect x="3" y="7" width="26" height="18" rx="5" fill="#d8261b" stroke="#6d0b06"/><path d="M13 11v10l9-5z" fill="#fff"/>',
  XpIcons.duplicate: '<rect x="3" y="3" width="17" height="21" fill="#fff" stroke="#555"/><rect x="11" y="9" width="17" height="21" fill="#fff" stroke="#555"/><path d="M14 15h11M14 19h11M14 23h7" stroke="#3b8cf5" stroke-width="2"/>',
  XpIcons.power: '<rect x="3" y="3" width="26" height="26" rx="4" fill="#e0532e" stroke="#7a1d07"/><path d="M11 11a8 8 0 1 0 10 0" fill="none" stroke="#fff" stroke-width="3"/><path d="M16 7v9" stroke="#fff" stroke-width="3"/>',
  XpIcons.pin: '<path d="M11 3h10l-2 9 5 5H8l5-5z" fill="#e0342a" stroke="#7a1010"/><path d="M16 17v12" stroke="#555" stroke-width="2"/>',
  XpIcons.list:
      '<rect x="4" y="3" width="24" height="26" fill="#fff" stroke="#555"/><path d="M8 9h16M8 14h16M8 19h16M8 24h10" stroke="#1d3c78" stroke-width="2"/>',
  XpIcons.plus: '<rect x="4" y="3" width="24" height="26" fill="#fff" stroke="#555"/><path d="M16 9v14M9 16h14" stroke="#2a8a2a" stroke-width="4"/>',
  XpIcons.star: '<path d="M16 2l4 9 10 1-7.5 7 2 10L16 24l-8.5 5 2-10L2 12l10-1z" fill="#ffd34a" stroke="#9a6a00"/>',
  XpIcons.person: '<circle cx="16" cy="10" r="6" fill="#5aa0ff" stroke="#0a246a"/><path d="M5 29c0-8 5-12 11-12s11 4 11 12z" fill="#2a64e0" stroke="#0a246a"/>',
  XpIcons.disc: '<circle cx="16" cy="16" r="13" fill="#d8dde8" stroke="#666"/><path d="M16 3a13 13 0 0 1 13 13" stroke="#ff9cf0" stroke-width="4" fill="none" opacity=".6"/><path d="M5 12a12 12 0 0 1 7-8" stroke="#8cf" stroke-width="3" fill="none"/><circle cx="16" cy="16" r="4" fill="#fff" stroke="#666"/>',
  XpIcons.play: '<path d="M9 5v22l18-11z" fill="#1d3c78"/>',
  XpIcons.shuffle:
      '<path d="M4 9h6l12 14h5M4 23h6l12-14h5" stroke="#1d3c78" stroke-width="3" fill="none"/><path d="M24 5l5 4-5 4zM24 19l5 4-5 4z" fill="#1d3c78"/>',
  XpIcons.refresh: '<path d="M26 16a10 10 0 1 1-3-7" fill="none" stroke="#2a8a2a" stroke-width="4"/><path d="M19 3l7 6-8 3z" fill="#2a8a2a"/>',
  XpIcons.edit: '<rect x="4" y="3" width="20" height="26" fill="#fff" stroke="#555"/><path d="M8 9h12M8 14h12M8 19h6" stroke="#99a"/><path d="M27 9l-12 12-4 1 1-4 12-12z" fill="#ffd34a" stroke="#6b4b1d"/>',
  XpIcons.computer: '<rect x="4" y="4" width="24" height="17" fill="#ece9d8" stroke="#555"/><rect x="7" y="7" width="18" height="11" fill="#3a6ea5"/><path d="M9 25h14l2 3H7z" fill="#ccc" stroke="#555"/><path d="M14 21h4v4h-4z" fill="#bbb"/>',
};

class XpIcon extends StatelessWidget {
  final XpIcons icon;
  final double size;
  const XpIcon(this.icon, {super.key, this.size = 22});

  @override
  Widget build(BuildContext context) =>
      SvgPicture.string('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">${_svg[icon]}</svg>', width: size, height: size);
}
