import 'package:flutter/material.dart';

import 'meta.dart';
import 'poster_image.dart';

/// The catalog browse grid — image grid surface. Lazy via GridView.builder.
class CatalogScreen extends StatelessWidget {
  final List<Meta> items;
  const CatalogScreen({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.62,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final m = items[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image(image: PosterImage(m.poster ?? ''), fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 2),
            Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
