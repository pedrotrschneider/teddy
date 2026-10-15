import 'package:flutter/material.dart';
import '../media/media_item.dart';
import '../utils/media_image_helper.dart';
import '../widgets/optimized_media_image.dart';

/// Loading chrome stays independent of control visibility and never takes
/// focus. Reuse the same logo/image cache as the browse banners.
class TedPlayerLoading extends StatefulWidget {
  final MediaItem media;
  const TedPlayerLoading({super.key, required this.media});
  @override
  State<TedPlayerLoading> createState() => _TedPlayerLoadingState();
}

class _TedPlayerLoadingState extends State<TedPlayerLoading> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  late final _curve = CurvedAnimation(parent: _pulse, curve: Curves.easeInOutSine);
  late final _opacity = Tween<double>(begin: .55, end: 1).animate(_curve);
  late final _scale = Tween<double>(begin: .94, end: 1.06).animate(_curve);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = .5;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Semantics(
      label: 'Loading video',
      liveRegion: true,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: .3),
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.maxWidth * .5).clamp(120.0, 400.0);
              final height = (constraints.maxHeight * .22).clamp(48.0, 160.0);
              return FadeTransition(
                opacity: _opacity,
                child: ScaleTransition(
                  scale: _scale,
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: OptimizedMediaImage(
                      client: null,
                      imagePath: widget.media.clearLogoPath,
                      imageType: ImageType.heroLogo,
                      fit: BoxFit.contain,
                      logoToneRemapMixed: false,
                      alignment: Alignment.center,
                      width: width,
                      height: height,
                      placeholder: (context, _) => _title(),
                      errorWidget: (context, _, _) => _title(),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _title() => Center(
    child: Text(
      widget.media.grandparentTitle ?? widget.media.title ?? 'Loading video',
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
    ),
  );
}
