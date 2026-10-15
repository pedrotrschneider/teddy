const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String tedReleaseDate(DateTime? date) =>
    date == null ? 'Release date unavailable' : 'Released ${date.day} ${_months[date.month - 1]} ${date.year}';
