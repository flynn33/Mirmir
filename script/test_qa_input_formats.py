#!/usr/bin/env python3
"""Regression checks for the independent synthetic format QA gate."""

import unittest

from qa_input_formats import verify_display_clock, verify_picture_order


class PictureOrderTests(unittest.TestCase):
    def setUp(self):
        self.frames = [bytes([20, 30, 40]), bytes([80, 90, 100]), bytes([150, 160, 170])]

    def testAcceptsSmallEncoderChangesAtCorrectDisplayPositions(self):
        result = verify_picture_order(self.frames, [bytes(x + 1 for x in f) for f in self.frames])
        self.assertTrue(result["displayOrderPassed"])
        self.assertEqual(result["frames"], 3)

    def testRejectsReorderedPicturesWithUnchangedCount(self):
        with self.assertRaisesRegex(ValueError, "Picture 1"):
            verify_picture_order(self.frames, [self.frames[0], self.frames[2], self.frames[1]])

    def testRejectsDuplicatedPictureWithUnchangedCount(self):
        with self.assertRaisesRegex(ValueError, "Picture 2"):
            verify_picture_order(self.frames, [self.frames[0], self.frames[1], self.frames[1]])

    def testRejectsMissingPicture(self):
        with self.assertRaisesRegex(ValueError, "count changed"):
            verify_picture_order(self.frames, self.frames[:-1])

    def testRejectsAmbiguousFixtureAndTiedMatch(self):
        with self.assertRaisesRegex(ValueError, "cannot distinguish"):
            verify_picture_order([b"a", b"a"], [b"a", b"a"])
        with self.assertRaisesRegex(ValueError, "uniquely match"):
            verify_picture_order([bytes([0]), bytes([2])], [bytes([1]), bytes([2])])


class DisplayClockTests(unittest.TestCase):
    def testAcceptsExactRationalClock(self):
        verify_display_clock([index * 25 for index in range(72)], "1/600")

    def testRejectsReorderedAndRoundedPresentationTimes(self):
        reordered = list(range(72))
        reordered[1], reordered[2] = reordered[2], reordered[1]
        with self.assertRaisesRegex(ValueError, "exact 24 fps"):
            verify_display_clock(reordered, "1/24")
        with self.assertRaisesRegex(ValueError, "exact 24 fps"):
            verify_display_clock([round(index * 1000 / 24) for index in range(72)], "1/1000")

    def testRejectsMissingPictureTimestamp(self):
        with self.assertRaisesRegex(ValueError, "all 72"):
            verify_display_clock(list(range(71)), "1/24")


if __name__ == "__main__":
    unittest.main()
