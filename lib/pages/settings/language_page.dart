import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_dropdown.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';

/// Game language + keyboard layout sent to the NVIDIA server on launch.
class LanguagePage extends StatelessWidget {
  final AppServices services;

  const LanguagePage({super.key, required this.services});

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Language & Input',
      showBack: true,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final s = services.settings;
          return NeonCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                NeonSettingTile(
                  icon: Icons.language,
                  title: 'Game language',
                  trailing: NeonDropdown<GameLanguage>(
                    value: s.gameLanguage,
                    onChanged: (v) {
                      if (v != null) s.gameLanguage = v;
                    },
                    items: GameLanguage.values
                        .map((l) => NeonDropdownItem(l, _languageLabel(l)))
                        .toList(),
                  ),
                ),
                const Divider(height: 1),
                NeonSettingTile(
                  icon: Icons.keyboard_outlined,
                  title: 'Keyboard layout',
                  trailing: NeonDropdown<KeyboardLayout>(
                    value: s.keyboardLayout,
                    onChanged: (v) {
                      if (v != null) s.keyboardLayout = v;
                    },
                    items: KeyboardLayout.values
                        .map((l) => NeonDropdownItem(l, _layoutLabel(l)))
                        .toList(),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _languageLabel(GameLanguage l) {
    const names = {
      GameLanguage.enUS: 'English (US)',
      GameLanguage.enGB: 'English (UK)',
      GameLanguage.deDE: 'Deutsch',
      GameLanguage.frFR: 'Français',
      GameLanguage.esES: 'Español (ES)',
      GameLanguage.esMX: 'Español (MX)',
      GameLanguage.itIT: 'Italiano',
      GameLanguage.ptPT: 'Português (PT)',
      GameLanguage.ptBR: 'Português (BR)',
      GameLanguage.ruRU: 'Русский',
      GameLanguage.plPL: 'Polski',
      GameLanguage.trTR: 'Türkçe',
      GameLanguage.jaJP: '日本語',
      GameLanguage.koKR: '한국어',
      GameLanguage.zhCN: '简体中文',
    };
    return names[l] ?? l.name;
  }

  String _layoutLabel(KeyboardLayout l) {
    const names = {
      KeyboardLayout.enUs: 'English (US)',
      KeyboardLayout.enGb: 'English (UK)',
      KeyboardLayout.deDe: 'Deutsch',
      KeyboardLayout.frFr: 'Français',
      KeyboardLayout.esEs: 'Español',
      KeyboardLayout.esMx: 'Español (MX)',
      KeyboardLayout.itIt: 'Italiano',
      KeyboardLayout.ptPt: 'Português',
      KeyboardLayout.ptBr: 'Português (BR)',
      KeyboardLayout.ruRu: 'Русский',
      KeyboardLayout.plPl: 'Polski',
      KeyboardLayout.trTr: 'Türkçe',
      KeyboardLayout.jaJp: '日本語',
      KeyboardLayout.koKr: '한국어',
      KeyboardLayout.zhCn: '简体中文',
      KeyboardLayout.zhTw: '繁體中文',
    };
    return names[l] ?? l.name;
  }
}
