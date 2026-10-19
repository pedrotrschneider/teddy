import 'package:flutter/material.dart';
import 'ted_rating.dart';

const tedAccountRatingScale = .69;
const tedAccountRatingOutset = .15;

class TedRatingBadge extends StatelessWidget {
  final int rating;
  final double size;
  const TedRatingBadge({super.key, required this.rating, this.size = 26});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tedRatingNames[rating - 1],
    child: Semantics(
      label: tedRatingNames[rating - 1],
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * .16),
        decoration: BoxDecoration(
          color: Color(tedRatingColors[rating - 1]),
          shape: BoxShape.circle,
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 3)],
        ),
        child: TedRatingIcon(rating: rating),
      ),
    ),
  );
}

class TedRatingIcon extends StatelessWidget {
  final int rating;
  const TedRatingIcon({super.key, required this.rating});
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, bounds) {
        final size = bounds.biggest.shortestSide;
        final icon = rating == 4
            ? Icons.remove
            : rating < 4
            ? Icons.thumb_down
            : Icons.thumb_up;
        return Center(
          child: SizedBox.square(
            dimension: size,
            child: rating == 1 || rating == 7
                ? CustomPaint(painter: _RatingPainter(rating))
                : rating == 2 || rating == 6
                ? Stack(
                    children: [
                      Positioned(
                        top: 0,
                        left: 0,
                        child: Icon(icon, size: size * .66, color: Colors.white),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Icon(icon, size: size * .66, color: Colors.white),
                      ),
                    ],
                  )
                : Icon(icon, size: size, color: Colors.white),
          ),
        );
      },
    );
  }
}

class _RatingPainter extends CustomPainter {
  final int rating;
  const _RatingPainter(this.rating);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final white = Paint()..color = Colors.white;
    if (rating == 1) {
      final path = Path()
        ..moveTo(8, 8)
        ..cubicTo(6, 6, 15, 5, 12, 1)
        ..cubicTo(18, 3, 20, 8, 16, 9)
        ..cubicTo(20, 8, 22, 13, 19, 14)
        ..cubicTo(24, 14, 24, 21, 19, 21)
        ..lineTo(5, 21)
        ..cubicTo(0, 21, 0, 15, 4, 14)
        ..cubicTo(1, 12, 4, 8, 8, 8)
        ..close();
      canvas.drawPath(path, white);
      final dark = Paint()..color = Color(tedRatingColors[0]);
      canvas.drawCircle(const Offset(9, 14), 1.4, dark);
      canvas.drawCircle(const Offset(15, 14), 1.4, dark);
    } else {
      // Open palms with raised fingers, mirrored around the centre.
      final hand = Path()
        ..moveTo(2, 23)
        ..lineTo(2, 13)
        ..lineTo(3, 9)
        ..lineTo(4, 10)
        ..lineTo(4, 14)
        ..lineTo(4, 5)
        ..lineTo(5, 4)
        ..lineTo(6, 5)
        ..lineTo(6, 12)
        ..lineTo(6, 2)
        ..lineTo(7, 1)
        ..lineTo(8, 2)
        ..lineTo(8, 12)
        ..lineTo(8, 4)
        ..lineTo(9, 3)
        ..lineTo(10, 4)
        ..lineTo(10, 14)
        ..lineTo(12, 11)
        ..lineTo(13, 12)
        ..lineTo(11, 19)
        ..lineTo(8, 23)
        ..close();
      void drawHand() {
        canvas.save();
        canvas.translate(.75, 3.6);
        canvas.scale(.7);
        canvas.drawPath(hand, white);
        canvas.restore();
      }

      drawHand();
      canvas.translate(24, 0);
      canvas.scale(-1, 1);
      drawHand();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RatingPainter oldDelegate) => oldDelegate.rating != rating;
}
