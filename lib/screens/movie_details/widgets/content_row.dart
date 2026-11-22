import 'package:flutter/material.dart';

import '../movie_details_screen.dart';
import '../../movies/widgets/movie_card.dart';

class ContentRow extends StatelessWidget {
  final String title;
  final List<dynamic> items;
  final ValueChanged<dynamic>? onItemTap;

  const ContentRow({
    super.key,
    required this.title,
    required this.items,
    this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 20,
          ),
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),

        const SizedBox(height: 18),

        SizedBox(
          height: 270,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
            ),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              return SizedBox(
                width: 180,
                child: MovieCard(
                  item: items[index],
                  onTap: () {
                    if (onItemTap != null) {
                      onItemTap!(items[index]);
                      return;
                    }
                    // Push a new MovieDetailsScreen on top of this one
                    // (rather than replacing a single overlay flag) so
                    // that back correctly returns to *this* movie, not
                    // straight out to the Movies tab.
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MovieDetailsScreen(
                          itemId: items[index]["Id"],
                          initialItem: Map<String, dynamic>.from(items[index]),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
