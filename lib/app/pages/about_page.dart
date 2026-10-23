part of '../app.dart';

class _AboutPage extends StatefulWidget {
  const _AboutPage({super.key, this.loader});

  final AboutInfoLoader? loader;

  @override
  State<_AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<_AboutPage> {
  AboutInfo? _info;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final info = await (widget.loader ?? AboutInfoLoader()).load();
      if (mounted) setState(() => _info = info);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final info = _info;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final colors = Theme.of(context).extension<AppColors>()!;
    Widget metadataRow({required Key key, required String value}) => Padding(
      key: key,
      padding: EdgeInsets.symmetric(
        horizontal: typography.spacingMd,
        vertical: typography.spacingSm,
      ),
      child: Text(value, style: typography.bodyMedium),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsSectionTitle(title: l10n.aboutSubDock),
        _SurfacePanel(
          key: const ValueKey('settings-about-card'),
          padding: EdgeInsets.zero,
          child: info == null
              ? Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: typography.spacingMd,
                    vertical: typography.spacingSm,
                  ),
                  child: _error == null
                      ? Text(l10n.aboutMetadataLoading)
                      : Text(
                          '${l10n.aboutMetadataUnavailable}: ${_localizedError(l10n, _error)}',
                        ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    metadataRow(
                      key: const ValueKey('about-version'),
                      value: '${l10n.aboutVersion}: ${info.version}',
                    ),
                    Divider(color: colors.divider, height: 1),
                    metadataRow(
                      key: const ValueKey('about-build-number'),
                      value:
                          '${l10n.aboutBuildNumber}: ${info.buildNumber.isEmpty ? '-' : info.buildNumber}',
                    ),
                    Divider(color: colors.divider, height: 1),
                    metadataRow(
                      key: const ValueKey('about-license'),
                      value: '${l10n.aboutLicense}: $subDockLicenseId',
                    ),
                    Divider(color: colors.divider, height: 1),
                    metadataRow(
                      key: const ValueKey('about-homepage'),
                      value:
                          '${l10n.aboutProjectHomepage}: $subDockProjectHomepage',
                    ),
                    Divider(color: colors.divider, height: 1),
                    metadataRow(
                      key: const ValueKey('about-os'),
                      value:
                          '${l10n.aboutOperatingSystem}: ${info.operatingSystem}',
                    ),
                    Divider(color: colors.divider, height: 1),
                    metadataRow(
                      key: const ValueKey('about-architecture'),
                      value: '${l10n.aboutArchitecture}: ${info.architecture}',
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Provides scrolling for the About content inside the shared shell.
class _ShellAboutPage extends StatelessWidget {
  const _ShellAboutPage({super.key, this.loader});

  final AboutInfoLoader? loader;

  @override
  Widget build(BuildContext context) {
    final typography = Theme.of(context).extension<AppTypography>()!;
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    return ListView(
      key: const ValueKey('about-list'),
      padding: EdgeInsets.only(
        left: compact ? typography.spacingSm : typography.spacingLg,
        top: compact ? typography.spacingSm : typography.spacingLg,
        right: compact ? typography.spacingSm : typography.spacingLg,
        bottom: typography.spacingLg,
      ),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: _AboutPage(loader: loader),
          ),
        ),
      ],
    );
  }
}
