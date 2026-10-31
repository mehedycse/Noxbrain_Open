import 'package:flutter/material.dart';
import '../theme.dart';

class MetricItem {
  final String label;
  final String value;
  final String unit;

  MetricItem(this.label, this.value, this.unit);
}

class MetricCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color accentColor;
  final Widget? trailingWidget;
  final String? badgeText;
  final Color? badgeColor;
  final List<MetricItem> items;
  final Widget? extraContent;

  const MetricCard({
    super.key,
    required this.title,
    required this.icon,
    required this.accentColor,
    this.trailingWidget,
    this.badgeText,
    this.badgeColor,
    required this.items,
    this.extraContent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SolarTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: SolarTheme.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Card Title Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(icon, color: accentColor, size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: accentColor,
                          ),
                          maxLines: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (trailingWidget != null)
                trailingWidget!
              else if (badgeText != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (badgeColor ?? accentColor).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (badgeColor ?? accentColor).withOpacity(0.35),
                    ),
                  ),
                  child: Text(
                    badgeText!,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: badgeColor ?? accentColor,
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 14),

          // Horizontal Row of Sub-tiles (matching reference 3, 4, or 5 in a row)
          Row(
            children: items.asMap().entries.map((entry) {
              final idx = entry.key;
              final item = entry.value;

              return Expanded(
                child: Container(
                  margin: EdgeInsets.only(left: idx > 0 ? 5 : 0),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101423),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF242A42)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        item.label,
                        style: const TextStyle(
                          fontSize: 9,
                          color: Color(0xFF8693AB),
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: item.value,
                                style: TextStyle(
                                  fontSize: items.length >= 5 ? 13.5 : (items.length == 4 ? 15.5 : 17.5),
                                  fontWeight: FontWeight.bold,
                                  color: SolarTheme.textPrimary,
                                ),
                              ),
                              if (item.unit.isNotEmpty && item.unit != '—')
                                TextSpan(
                                  text: ' ${item.unit}',
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                    color: const Color(0xFFA0ADC4),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),

          if (extraContent != null) ...[
            const SizedBox(height: 12),
            extraContent!,
          ],
        ],
      ),
    );
  }
}
