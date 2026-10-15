/// Money.
///
/// The store is **PKR only**. MEMORY.md §3: "No currency selector, no USD
/// anywhere, no floats." Prices travel as whole paisa in an integer
/// (`price_cents: 780000` is Rs 7,800) and are turned into text exactly once,
/// here.
///
/// A `double` is never used for a price. 780000 paisa is not exactly
/// representable in binary floating point, so a double-based price eventually
/// renders as "Rs 7,799.999999" on some device.
library;

/// An integer number of paisa. 100 paisa = 1 rupee.
class Price implements Comparable<Price> {
  const Price.paisa(this.paisa) : assert(paisa >= 0, 'price cannot be negative');

  final int paisa;

  /// const so it can initialise `const` fields such as `Store.empty`.
  static const Price zero = Price.paisa(0);

  int get rupees => paisa ~/ 100;
  int get remainder => paisa % 100;

  /// "Rs 7,800".
  ///
  /// Whole rupees when the price is a whole number of rupees, which is how
  /// every price in the catalog is written. If a price ever carries paisa, the
  /// fraction is shown rather than silently rounded away — dropping 50 paisa
  /// off a displayed price is the kind of thing nobody notices until a customer
  /// is charged the wrong amount.
  String get formatted {
    final whole = _group(rupees.toString());
    if (remainder == 0) return 'Rs $whole';
    return 'Rs $whole.${remainder.toString().padLeft(2, '0')}';
  }

  @override
  int compareTo(Price other) => paisa.compareTo(other.paisa);

  Price operator +(Price other) => Price.paisa(paisa + other.paisa);
  Price operator -(Price other) => Price.paisa((paisa - other.paisa).clamp(0, 1 << 62));

  bool operator <(Price other) => paisa < other.paisa;
  bool operator >(Price other) => paisa > other.paisa;
  bool operator <=(Price other) => paisa <= other.paisa;
  bool operator >=(Price other) => paisa >= other.paisa;

  @override
  bool operator ==(Object other) => other is Price && other.paisa == paisa;

  @override
  int get hashCode => paisa.hashCode;

  @override
  String toString() => formatted;

  /// Insert thousands separators: "17800" -> "17,800".
  static String _group(String digits) {
    final negative = digits.startsWith('-');
    final body = negative ? digits.substring(1) : digits;
    final buffer = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      if (i > 0 && (body.length - i) % 3 == 0) buffer.write(',');
      buffer.write(body[i]);
    }
    return negative ? '-$buffer' : buffer.toString();
  }
}